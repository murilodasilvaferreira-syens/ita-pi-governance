-- =====================================================================================
-- gold_views.sql — views de diagnóstico do inventário do PI System
--
-- Executar no SQL analytics endpoint do Lakehouse lh_pi_governance, DEPOIS de rodar
-- 01_bronze_ingest, 02_silver_transform e 03_gold_views.
--
-- Divisão de responsabilidade:
--   - o notebook 03 materializa o que exige janela sobre a série histórica (deltas, baselines)
--   - este arquivo expõe filtros sobre o snapshot atual, baratos de manter e diretos no Power BI
--
-- LEIA ANTES DE LIGAR ALERTAS:
--   - is_stale por tag NÃO significa interface parada (ver gold_vw_interface_suspeita)
--   - has_ever_received_data é heurístico (ver gold_vw_tags_sem_dados)
--   - só removal_status = 'confirmed' deve alertar em tag removida
-- =====================================================================================


-- -------------------------------------------------------------------------------------
-- Tags órfãs: existem no Data Archive e nenhum atributo do AF aponta para elas.
-- Candidatas a limpeza, mas confirme com a área antes: órfã não é sinônimo de inútil.
-- -------------------------------------------------------------------------------------
CREATE OR ALTER VIEW gold_vw_tags_orfas AS
SELECT
    h.snapshot_date,
    h.point_id,
    h.tag_name,
    h.point_source,
    h.point_type,
    h.descriptor,
    h.creation_date,
    h.creator,
    h.value_time,
    h.age_days,
    h.has_ever_received_data
FROM gold_fact_tag_health h
WHERE h.snapshot_ts = (SELECT MAX(snapshot_ts) FROM gold_fact_tag_health)
  AND h.is_orfa = 1;
GO


-- -------------------------------------------------------------------------------------
-- Tags sem update há mais tempo que o limite.
-- ATENÇÃO: com compressão ligada, uma tag estável fica dias sem gravar e continua saudável.
-- Esta view lista o sintoma; o diagnóstico de interface parada é gold_vw_interface_suspeita.
-- -------------------------------------------------------------------------------------
CREATE OR ALTER VIEW gold_vw_tags_stale AS
SELECT
    h.snapshot_date,
    h.point_id,
    h.tag_name,
    h.point_source,
    h.descriptor,
    h.value_time,
    h.age_hours,
    h.age_days,
    h.is_good,
    h.compressing,
    h.af_attribute_count
FROM gold_fact_tag_health h
WHERE h.snapshot_ts = (SELECT MAX(snapshot_ts) FROM gold_fact_tag_health)
  AND h.is_stale = 1
  AND h.has_ever_received_data = 1;
GO


-- -------------------------------------------------------------------------------------
-- Interface suspeita de parada.
-- O sinal confiável é AGREGADO por pointsource, comparado contra a própria linha de base
-- histórica daquele pointsource — não um limite global por tag.
-- 'sem_baseline' significa que ainda não há snapshots suficientes para julgar.
-- -------------------------------------------------------------------------------------
CREATE OR ALTER VIEW gold_vw_interface_suspeita AS
WITH por_snapshot AS (
    SELECT
        snapshot_ts,
        point_source,
        COUNT(*)                                     AS tags,
        SUM(CASE WHEN is_stale = 1 THEN 1 ELSE 0 END) AS tags_stale
    FROM gold_fact_tag_health
    WHERE has_ever_received_data = 1
    GROUP BY snapshot_ts, point_source
),
com_ratio AS (
    SELECT *, CAST(tags_stale AS FLOAT) / NULLIF(tags, 0) AS ratio_stale
    FROM por_snapshot
),
atual AS (
    SELECT * FROM com_ratio
    WHERE snapshot_ts = (SELECT MAX(snapshot_ts) FROM com_ratio)
),
baseline AS (
    SELECT point_source, AVG(ratio_stale) AS ratio_medio, COUNT(*) AS amostras
    FROM com_ratio
    WHERE snapshot_ts < (SELECT MAX(snapshot_ts) FROM com_ratio)
    GROUP BY point_source
)
SELECT
    a.point_source,
    a.tags,
    a.tags_stale,
    a.ratio_stale,
    b.ratio_medio,
    b.amostras                                  AS snapshots_de_baseline,
    CASE
        WHEN b.amostras IS NULL OR b.amostras < 5     THEN 'sem_baseline'
        WHEN a.ratio_stale > b.ratio_medio + 0.25     THEN 'suspeita'
        ELSE 'normal'
    END AS avaliacao
FROM atual a
LEFT JOIN baseline b ON b.point_source = a.point_source;
GO


-- -------------------------------------------------------------------------------------
-- Tags que nunca receberam dado.
--
-- ⚠ SINAL HEURÍSTICO, NÃO GARANTIA. Restore de backup, tag realimentada depois de parada e
-- tag alimentada uma única vez há muito tempo furam a detecção.
-- NÃO conecte alerta a esta view antes de revisar a distribuição. NUNCA delete uma tag com
-- base apenas nela: delete apaga o histórico e é irreversível.
-- -------------------------------------------------------------------------------------
CREATE OR ALTER VIEW gold_vw_tags_sem_dados AS
SELECT
    h.snapshot_date,
    h.point_id,
    h.tag_name,
    h.point_source,
    h.point_type,
    h.descriptor,
    h.creation_date,
    h.creator,
    h.is_pt_created,
    h.snapshot_value,
    h.af_attribute_count,
    h.is_orfa
FROM gold_fact_tag_health h
WHERE h.snapshot_ts = (SELECT MAX(snapshot_ts) FROM gold_fact_tag_health)
  AND h.has_ever_received_data = 0;
GO


-- -------------------------------------------------------------------------------------
-- Data Reference quebrado: o atributo do AF aponta para uma tag que não existe no Data Archive.
-- 'unparsed' é caso à parte: indica que o parser de ConfigString não cobriu um formato,
-- não que o DR esteja errado. Investigue o parser antes de investigar a configuração.
-- -------------------------------------------------------------------------------------
CREATE OR ALTER VIEW gold_vw_dr_quebrado AS
SELECT
    a.snapshot_date,
    a.element_path,
    a.element_name,
    a.element_template,
    a.attribute_name,
    a.attribute_path,
    a.resolved_tag,
    a.resolved_point_id,
    a.parse_status,
    a.dr_status,
    a.has_sensitive_hint
FROM gold_attribute_public a
WHERE a.snapshot_date = (SELECT MAX(snapshot_date) FROM gold_attribute_public)
  AND a.dr_status IN ('broken', 'unparsed');
GO


-- -------------------------------------------------------------------------------------
-- Tag renomeada: o point_id do ConfigString resolve para uma tag de nome diferente do
-- resolved_tag. Sinal de que alguém renomeou a tag e o AF ficou com o nome antigo.
-- -------------------------------------------------------------------------------------
CREATE OR ALTER VIEW gold_vw_tag_renomeada AS
SELECT
    a.snapshot_date,
    a.element_path,
    a.attribute_name,
    a.resolved_tag        AS nome_no_configstring,
    a.matched_point_name  AS nome_atual_no_pi,
    a.resolved_point_id   AS point_id
FROM gold_attribute_public a
WHERE a.snapshot_date = (SELECT MAX(snapshot_date) FROM gold_attribute_public)
  AND a.name_id_mismatch = 1;
GO


-- -------------------------------------------------------------------------------------
-- Analyses em erro — a falha silenciosa mais comum do AF.
-- status_source diz se runtime_status é status real ou apenas listagem: se for
-- 'FallbackListOnly', esta view fica vazia porque não há status, e não porque está tudo bem.
-- -------------------------------------------------------------------------------------
CREATE OR ALTER VIEW gold_vw_analysis_erro AS
SELECT
    a.snapshot_date,
    a.analysis_name,
    a.analysis_path,
    a.target_name,
    a.target_path,
    a.template_name,
    a.runtime_status,
    a.last_evaluation_status,
    a.last_trigger_time,
    a.error_count,
    a.success_count,
    a.skip_count,
    a.status_source
FROM silver_dim_analysis a
WHERE a.snapshot_date = (SELECT MAX(snapshot_date) FROM silver_dim_analysis)
  AND (a.runtime_status IN ('Error', 'Stopped') OR a.error_count > 0);
GO


-- -------------------------------------------------------------------------------------
-- Cobertura por reator: quanto da estrutura de cada reator está efetivamente ligada ao PI.
-- Reatores seguem o padrão K#####.
-- -------------------------------------------------------------------------------------
CREATE OR ALTER VIEW gold_vw_cobertura_reator AS
SELECT
    a.snapshot_date,
    a.element_name                                                        AS reator,
    a.element_path,
    a.element_template,
    COUNT(*)                                                              AS atributos_total,
    SUM(CASE WHEN a.dr_status = 'ok'      THEN 1 ELSE 0 END)              AS atributos_ligados,
    SUM(CASE WHEN a.dr_status = 'broken'  THEN 1 ELSE 0 END)              AS atributos_dr_quebrado,
    SUM(CASE WHEN a.dr_status = 'dynamic' THEN 1 ELSE 0 END)              AS atributos_dinamicos,
    SUM(CASE WHEN a.dr_status = 'no_config' THEN 1 ELSE 0 END)            AS atributos_estaticos,
    CAST(SUM(CASE WHEN a.dr_status = 'ok' THEN 1 ELSE 0 END) AS FLOAT)
        / NULLIF(COUNT(*), 0)                                             AS cobertura
FROM gold_attribute_public a
WHERE a.snapshot_date = (SELECT MAX(snapshot_date) FROM gold_attribute_public)
  AND a.element_name LIKE 'K[0-9][0-9][0-9][0-9][0-9]'
GROUP BY a.snapshot_date, a.element_name, a.element_path, a.element_template;
GO


-- -------------------------------------------------------------------------------------
-- Deltas — views finas sobre as tabelas materializadas pelo notebook 03.
-- Só o que é acionável: linhas com delta_status 'gap' ficam visíveis mas separadas.
-- -------------------------------------------------------------------------------------
CREATE OR ALTER VIEW gold_vw_delta_tag_criada AS
SELECT *
FROM gold_delta_tag_criada
WHERE delta_status = 'ok';
GO

-- ALERTA FORTE: delete de PI Point apaga o histórico e é irreversível.
-- Somente 'confirmed' — ausência em um único snapshot costuma ser falha de coleta.
CREATE OR ALTER VIEW gold_vw_delta_tag_removida AS
SELECT *
FROM gold_delta_tag_removida
WHERE removal_status = 'confirmed'
  AND delta_status = 'ok';
GO

-- Falso positivo de remoção = a coleta falhou naquele ciclo. Não é alerta de tag, é de pipeline.
CREATE OR ALTER VIEW gold_vw_coleta_instavel AS
SELECT
    snapshot_date,
    COUNT(*) AS tags_que_sumiram_e_voltaram
FROM gold_delta_tag_removida
WHERE removal_status = 'false_positive'
GROUP BY snapshot_date;
GO

CREATE OR ALTER VIEW gold_vw_delta_atributo_alterado AS
SELECT *
FROM gold_delta_atributo_alterado
WHERE delta_status = 'ok';
GO

-- Lacunas na série: PAD parado, feriado, máquina desligada. Fica visível em vez de virar buraco.
CREATE OR ALTER VIEW gold_vw_lacunas_de_coleta AS
SELECT
    snapshot_date,
    prev_snapshot_date,
    gap_hours,
    delta_status
FROM gold_snapshot_pair
WHERE delta_status IN ('gap', 'first');
GO


-- -------------------------------------------------------------------------------------
-- Desempenho da coleta: detecta o dia em que o carregamento em lote parar de funcionar.
-- -------------------------------------------------------------------------------------
CREATE OR ALTER VIEW gold_vw_run_performance AS
SELECT
    snapshot_date,
    snapshot_ts,
    run_type,
    run_status,
    dataset,
    dataset_status,
    row_count,
    duration_ms,
    CAST(baseline_duration_ms AS BIGINT) AS baseline_duration_ms,
    is_degradado,
    run_duration_ms,
    module_version,
    used_fallback_dir
FROM gold_run_performance;
GO


-- -------------------------------------------------------------------------------------
-- Feed consolidado de alertas, ordenado por custo de não perceber.
-- É esta view que o Power BI Data Alert / Power Automate deve observar.
--
-- gold_vw_tags_sem_dados está DELIBERADAMENTE fora: medir primeiro, alertar depois.
-- -------------------------------------------------------------------------------------
CREATE OR ALTER VIEW gold_vw_alertas AS
SELECT 'tag_removida'        AS tipo, 1 AS severidade, CAST(snapshot_date AS DATE) AS snapshot_date,
       tag_name              AS objeto,
       CONCAT('Tag removida do Data Archive (pointsource ', COALESCE(point_source, '?'), ')') AS detalhe
FROM gold_vw_delta_tag_removida
UNION ALL
SELECT 'interface_parada', 2, CAST(GETDATE() AS DATE),
       point_source,
       CONCAT(tags_stale, ' de ', tags, ' tags sem update — base histórica ',
              FORMAT(ratio_medio, 'P0'))
FROM gold_vw_interface_suspeita WHERE avaliacao = 'suspeita'
UNION ALL
SELECT 'analysis_erro', 2, snapshot_date,
       analysis_name,
       CONCAT('Analysis em ', runtime_status, ' no elemento ', COALESCE(target_name, '?'))
FROM gold_vw_analysis_erro WHERE runtime_status = 'Error'
UNION ALL
SELECT 'dr_quebrado', 3, snapshot_date,
       CONCAT(element_name, '|', attribute_name),
       CONCAT('Aponta para tag inexistente: ', COALESCE(resolved_tag, '(não resolvida)'))
FROM gold_vw_dr_quebrado
UNION ALL
SELECT 'tag_nova', 3, snapshot_date,
       tag_name,
       CONCAT('Tag criada por ', COALESCE(creator, '?'), ' fora do processo catalogado')
FROM gold_vw_delta_tag_criada
UNION ALL
SELECT 'coleta_degradada', 3, snapshot_date,
       dataset,
       CONCAT('Duração ', duration_ms, ' ms contra baseline ', baseline_duration_ms, ' ms')
FROM gold_vw_run_performance WHERE is_degradado = 1;
GO
