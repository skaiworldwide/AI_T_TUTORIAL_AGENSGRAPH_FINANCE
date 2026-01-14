-- # 금융거래 데이터 그래프 DB 구축 - 통합 실습 가이드 (Enhanced Visualization)
-- 
-- 이 노트북은 금융거래 원천 데이터를 활용하여 AgensGraph(그래프 DB)에 노드와 엣지를 구축하는 **전체 과정**을 포함합니다.
-- 각 단계는 **세부적인 작업 단위**로 분리되어 있으며, 작업 후 **데이터 미리보기(Head)**를 제공하여 진행 상황을 직관적으로 확인할 수 있습니다.
-- 
-- ## 0. 전체 로드맵 (Roadmap)
-- 
-- - [x] **Section 1: 초기화 및 환경 설정** (기초 테이블 및 레이블 생성)
-- - [x] **Section 2: 데이터 정제 (Cleansing)** (1/2차 정제, 노이즈 필터링, 컬럼 매핑)
-- - [x] **Section 3: 버텍스(Vertex) 데이터 준비** (기존 노드 검색, 신규/갱신 분류 Logic)
-- - [x] **Section 4: 노드(Node) 생성 및 속성 갱신** (VGRPH00, 식별자 배열 처리)
-- - [x] **Section 5: 엣지(Edge) 데이터 집계** (거래내역 배열화 Array Aggregation)
-- - [x] **Section 6: 엣지(Edge) 중복 제거 및 검색** (입지구분 1/2 통합, 004 당행 거래 정리)
-- - [x] **Section 7: 일반 엣지 생성 및 업데이트** (egrph{YY} 레이블 활용)
-- - [x] **Section 8: 대형 엣지(100UP) 처리** (고액 거래 별도 집계 및 EGRPH00 생성)
-- - [x] **Section 9: 최종 정비 및 월간 배치** (파티셔닝 삭제, Analyze, 월초 로직)

-- ## 1. 그래프 초기화 및 환경 설정
drop graph if exists am_graph cascade;
create graph am_graph;


-- 1.1 그래프 경로 설정 및 연도별 엣지 레이블 생성 (egrph25)
-- [Ref: 7.3.1 Time-based Partitioning]
-- 엣지 레이블을 연도별(egrph25, egrph26...)로 분리하여 관리합니다.
-- 이는 추후 과거 데이터(예: 2024년 데이터)를 삭제할 때 DROP TABLE 명령만으로 빠르게 정리하기 위함입니다.
SET graph_path TO am_graph;
CREATE VLABEL IF NOT EXISTS vgrph00;
CREATE ELABEL IF NOT EXISTS egrph25;



-- ## 2. 데이터 정제 (Cleansing)
-- 원천 데이터(`agbtch01`)로부터 1차 정제 테이블을 생성하고, 노이즈(Top 50 과다 거래 계좌)를 제거한 후 2차 정제 테이블을 만듭니다.

-- 2.1: 1차 정제 (Cleansing)
-- [Ref: 3.2.2 상대방 계좌번호 정제]
-- 1. cnprtacno parsing: '은행코드=계좌번호' 형태의 문자열에서 계좌번호만 축출합니다.
-- 2. Self-loop handling: 상대 계좌(cnprtacno)가 NULL인 경우(예: 현금 인출), 자신의 계좌번호(acno)로 채워 
--    그래프의 연결성이 끊어지지 않고 자기 자신에게 돌아오는 엣지(Loop)가 되도록 처리합니다.
DROP TABLE IF EXISTS tutorial_finance.tmp_agbtch01_20250701_clr;
CREATE TABLE tutorial_finance.tmp_agbtch01_20250701_clr AS
SELECT '계좌' as acnotype, rtrim(acno) as acno, rtrim(acnoname) as acnoname, '004' as acnobnkcd, '국민은행' as acnobnknm, 
       CASE 
           WHEN cnprtacno LIKE '%=%' THEN nullif(rtrim(split_part(cnprtacno, '=', 2)), '')
           ELSE COALESCE(rtrim(cnprtacno), acno) 
       END as cnprtacno, '계좌' as cnprtacnotype,
       COALESCE(NULLIF(rtrim(cnprtname),''), 'no_cnprtname') as cnprtname, 
       COALESCE(NULLIF(cnprtbnknm,''), 'no_cnprtbnknm') as cnprtbnknm,
	   COALESCE(NULLIF(cnprtbnkcd,''), 'no_cnprtbnkcd') as cnprtbnkcd,
       tranamt, tranymd, tranprcssyms, rapdstcd, prdctctrcnth, transerno, acncustidnfr,  
       hndinbnkcd, hndinbrncd,  sumry, tranuno
FROM tutorial_finance.tb_raw_data ;




-- 2.2: 노이즈 추출 및 제거
-- [Ref: 3.3.1 Filter Conditions - Super Nodes]
-- 하루에 50개 이상의 서로 다른 계좌와 거래하는 계좌(예: 집금 계좌, 쇼핑몰 결제 계좌)는 '노이즈(Noise)'로 간주합니다.
-- 이러한 '슈퍼 노드'는 그래프 탐색 시 성능을 급격히 저하시키므로 별도 관리하거나 제거합니다.
DROP TABLE IF EXISTS tutorial_finance.tmp_agbtch01_20250701_top50;
CREATE TABLE tutorial_finance.tmp_agbtch01_20250701_top50 AS
SELECT cnprtacno, count(*) as trans_count FROM tutorial_finance.tmp_agbtch01_20250701_clr
GROUP BY cnprtacno HAVING count(distinct acno) >= 50;

-- 노이즈 목록을 영구 테이블(agvclr02)에 백업 (추후 필터링에 재사용)
create table if not exists tutorial_finance.agvclr02 (cnprtacno text);
INSERT INTO tutorial_finance.agvclr02 (cnprtacno)
SELECT cnprtacno FROM tutorial_finance.tmp_agbtch01_20250701_top50
WHERE NOT EXISTS (SELECT 1 FROM tutorial_finance.agvclr02 WHERE cnprtacno = tutorial_finance.tmp_agbtch01_20250701_top50.cnprtacno);

-- 정제 테이블에서 노이즈 데이터 삭제
DELETE FROM tutorial_finance.tmp_agbtch01_20250701_clr
WHERE cnprtacno IN (SELECT cnprtacno FROM tutorial_finance.agvclr02);


-- 2.6: 고액 거래(100만원 이상) 분리
-- [Ref: 3.3.1 High Value Separation]
-- 분석 중요도가 높은 고액 거래(100만원 이상)는 별도 테이블로 분리합니다.
DROP TABLE IF EXISTS tutorial_finance.tmp_agbtch01_20250701_clr_100up;
CREATE TABLE tutorial_finance.tmp_agbtch01_20250701_clr_100up AS
SELECT * FROM tutorial_finance.tmp_agbtch01_20250701_clr WHERE tranamt >= 1000000;

-- ## 3. 버텍스(Vertex) 데이터 준비
-- 정제된 데이터에서 Unique한 버텍스(계좌, 이름 등)를 추출하고, 그래프에 이미 존재하는지(`agvclr00`, `vgrph00`) 확인하여 **신규 생성('Y')**과 **갱신('U')** 대상을 분류합니다.

-- 3.1: 임시 버텍스 테이블 생성 (Source & Target 통합)
-- [Ref: 5.1.1 Node Temp Table]
-- 거래 데이터에는 '나(acno)'와 '상대방(cnprtacno)'이 공존합니다.
-- UNION을 사용하여 이 둘을 합치고 중복을 제거(DISTINCT)하여, 금일 거래에 등장한 '모든 유니크한 계좌 목록'을 만듭니다.
DROP TABLE IF EXISTS tutorial_finance.tmp_amgraph_vt_20250701;
CREATE TABLE tutorial_finance.tmp_amgraph_vt_20250701 AS
SELECT acnotype, acno, acnoname, acnobnkcd, acnobnknm, acncustidnfr FROM (
    SELECT acnotype, acno, acnoname, acnobnkcd, acnobnknm, acncustidnfr FROM tutorial_finance.tmp_agbtch01_20250701_clr
    UNION 
    SELECT cnprtacnotype, cnprtacno, cnprtname, cnprtbnkcd, cnprtbnknm, 'no_idnfr' FROM tutorial_finance.tmp_agbtch01_20250701_clr
) T GROUP BY 1,2,3,4,5,6;




-- 3.2: 기존 노드 검색 (Linkage / Search Table)
-- [Ref: 5.4.1 Node ID Search]
-- 그래프 DB(vgrph00)에 해당 계좌가 이미 존재하는지 확인하기 위해 Graph ID와 속성(Properties)을 조회합니다.
-- 이 과정은 RDBMS 데이터와 Graph 데이터를 매핑하는 핵심 과정입니다.
CREATE TABLE IF NOT EXISTS tutorial_finance.tmp_amgraph_vt_20250701_search (id graphid, properties jsonb);

INSERT INTO tutorial_finance.tmp_amgraph_vt_20250701_search
SELECT id, properties FROM (
    LOAD FROM tutorial_finance.tmp_amgraph_vt_20250701 AS ro
    MATCH (a:vgrph00)
    WHERE a.acno = ro.acno AND a.bnkcd = ro.acnobnkcd
    RETURN id(a) as id, a::jsonb as properties
) T;

-- 3.3: CREATE_YN 판단 (신규/갱신 분류)
-- [Ref: 5.1.3 Node Classification]
-- 1. id가 NULL이면 -> 신규 생성 대상 ('Y')
-- 2. id는 있지만 식별자 배열(idnfr_arr)에 변동이 생겼으면 -> 업데이트 대상 ('U')
-- 3. 그 외 -> 변동 없음 ('N')
DROP TABLE IF EXISTS tutorial_finance.tmp_amgraph_vt_20250701_clr;
CREATE TABLE tutorial_finance.tmp_amgraph_vt_20250701_clr AS
SELECT tb1.*, tb2.id, tb2.properties->>'acncustidnfr_arr' as idnfr_arr,
    CASE
        WHEN tb2.id IS NULL THEN 'Y'
        WHEN NOT (tb2.properties->>'acncustidnfr_arr' LIKE '%' || tb1.acncustidnfr || '%') AND tb1.acncustidnfr <> 'no_idnfr' THEN 'U'
        ELSE 'N'
    END AS create_yn
FROM tutorial_finance.tmp_amgraph_vt_20250701 tb1
LEFT JOIN tutorial_finance.tmp_amgraph_vt_20250701_search tb2 
ON tb1.acno = tb2.properties->>'acno' AND tb1.acnobnkcd = tb2.properties->>'bnkcd';

-- ## 4. 노드(Node) 생성 및 정보 갱신
-- AgensGraph의 `LOAD` 문을 활용하여 VGRPH00 노드를 생성하거나 속성을 업데이트합니다.

SET graph_path TO am_graph;

-- 4.1: 신규 노드(Vertex) 생성
-- [Ref: 5.3.1 Bulk Node Creation]
-- 'Y'로 마킹된 데이터에 대해 노드를 생성합니다.
-- LOAD FROM은 메모리상에서 직접 그래프 객체를 생성하므로 INSERT 문보다 월등히 빠릅니다.
DROP TABLE IF EXISTS tutorial_finance.tmp_amgraph_vt_20250701_clr_create;
CREATE TABLE tutorial_finance.tmp_amgraph_vt_20250701_clr_create AS
SELECT acnotype, acno, acnoname, acnobnkcd, acnobnknm, 
       array_remove(array_agg(distinct acncustidnfr), 'no_idnfr') as idnfr_arr
FROM (select * from tutorial_finance.tmp_amgraph_vt_20250701_clr WHERE create_yn = 'Y') tb
GROUP BY 1,2,3,4,5;




LOAD FROM tutorial_finance.tmp_amgraph_vt_20250701_clr_create AS row
CREATE (v:VGRPH00 {type: row.acnotype, acno: row.acno, name: row.acnoname, bnkcd: row.acnobnkcd, bnknm: row.acnobnknm, acncustidnfr_arr: row.idnfr_arr});

-- 4.2: 기존 노드 속성 업데이트
-- [Ref: 5.3.2 Node Property Update]
-- 'U'로 마킹된 데이터는 기존 노드를 찾아 식별자 배열(acncustidnfr_arr)에 새로운 식별자를 추가(Append)합니다.
SET graph_path TO am_graph;

DROP TABLE IF EXISTS tutorial_finance.tmp_amgraph_vt_20250701_clr_update;
CREATE TABLE tutorial_finance.tmp_amgraph_vt_20250701_clr_update AS
SELECT id, array_remove(array_agg(distinct acncustidnfr), 'no_idnfr') as new_idnfrs
FROM tutorial_finance.tmp_amgraph_vt_20250701_clr WHERE create_yn = 'U'
GROUP BY id;

LOAD FROM tutorial_finance.tmp_amgraph_vt_20250701_clr_update AS row
MATCH (v:VGRPH00) WHERE id(v) = row.id
SET v.acncustidnfr_arr = v.acncustidnfr_arr + row.new_idnfrs;


DROP TABLE IF EXISTS tutorial_finance.tmp_amgraph_vt_20250701_search;
CREATE TABLE IF NOT EXISTS tutorial_finance.tmp_amgraph_vt_20250701_search (id graphid, properties jsonb);

INSERT INTO tutorial_finance.tmp_amgraph_vt_20250701_search
SELECT distinct on (id) id, properties FROM (
    LOAD FROM tutorial_finance.tmp_amgraph_vt_20250701 AS ro
    MATCH (a:vgrph00)
    WHERE a.acno = ro.acno AND a.bnkcd = ro.acnobnkcd
    RETURN id(a) as id, a::jsonb as properties
) T;





-- ## 5. 엣지(Edge) 데이터 집계 (Aggregation)
-- 거래 데이터를 출금/입금 단위로 묶고, 거래시간(`tranprcssyms`)과 금액(`tranamt`) 등을 배열로 집계합니다.

-- 5.1: 엣지 집계 (Array Aggregation)
-- [Ref: 5.2.1 Edge Aggregation]
-- 중요: 동일한 계좌 쌍(acno, cnprtacno) 사이의 하루치 거래가 100건이어도, 그래프에서는 1개의 엣지로 표현합니다.
-- 대신 100건의 상세 내역(시간, 금액 등)은 ARRAY_AGG를 사용하여 엣지의 속성(배열)으로 저장합니다.
-- 이를 통해 그래프 복잡도(Topology)를 낮추면서도 상세 내역(History)은 보존할 수 있습니다.
DROP TABLE IF EXISTS tutorial_finance.tmp_amgraph_edg_20250701;
CREATE TABLE tutorial_finance.tmp_amgraph_edg_20250701 AS
SELECT 
    acnotype, acno, acnoname, acnobnkcd, acnobnknm,
    cnprtacnotype, cnprtacno, cnprtname, cnprtbnkcd, cnprtbnknm,
    rapdstcd,
    ARRAY_AGG(tranprcssyms ORDER BY tranprcssyms) as tranprcssyms_arr,
    ARRAY_AGG(tranamt ORDER BY tranprcssyms) as tranamt_arr,
    ARRAY_AGG(sumry ORDER BY tranprcssyms) as sumry_arr,
    ARRAY_AGG(tranuno ORDER BY tranprcssyms) as tranuno_arr
FROM tutorial_finance.tmp_agbtch01_20250701_clr
GROUP BY 1,2,3,4,5,6,7,8,9,10,11;

CREATE INDEX tmp_edg_idx ON tutorial_finance.tmp_amgraph_edg_20250701 (rapdstcd, cnprtbnkcd);

-- ## 6. 엣지(Edge) 중복 제거 및 최종 정제
-- 양방향 거래(당행 간 이체 등)에서 발생하는 **입지구분 1(입금)과 2(출금)**의 중복 데이터를 제거하고,
-- 하나의 일관된 엣지 테이블(`..._clr`)로 병합합니다.

SET work_mem = '10GB';

-- 6.1: 중복 데이터 식별 (Double Entry Check)
-- [Ref: 5.2.2 Direction Unification]
-- 당행(004)간 거래의 경우, 하나의 거래가 '보내는 사람의 출금(2)'과 '받는 사람의 입금(1)'으로 두 번 기록됩니다.
-- 이 중복을 식별하기 위해 (계좌, 상대계좌, 거래내역배열)이 완벽히 일치하는 쌍을 찾습니다.
DROP TABLE IF EXISTS tutorial_finance.tmp_amgraph_edg_20250701_dup_check;
CREATE TABLE tutorial_finance.tmp_amgraph_edg_20250701_dup_check AS
SELECT t1.acno, t1.tranprcssyms_arr 
FROM (SELECT * FROM tutorial_finance.tmp_amgraph_edg_20250701 WHERE rapdstcd='1' AND cnprtbnkcd='004') t1
JOIN (SELECT * FROM tutorial_finance.tmp_amgraph_edg_20250701 WHERE rapdstcd='2' AND cnprtbnkcd='004') t2
ON t1.acno = t2.cnprtacno AND t1.tranprcssyms_arr = t2.tranprcssyms_arr;

-- 6.2: 최종 엣지 테이블 생성
-- 1. 출금 데이터(2)는 항상 신뢰하여 유지합니다.
-- 2. 입금 데이터(1) 중 위에서 식별된 중복은 제거합니다. (당행 거래 중복 제거)
-- 3. 타행 거래의 입금 데이터 등은 중복이 아니므로 유지합니다.
DROP TABLE IF EXISTS tutorial_finance.tmp_amgraph_edg_20250701_clr;
CREATE TABLE tutorial_finance.tmp_amgraph_edg_20250701_clr AS
SELECT * FROM (
    -- 출금 거래(2)는 모두 포함
    SELECT * FROM tutorial_finance.tmp_amgraph_edg_20250701 WHERE rapdstcd = '2'
    UNION ALL
    -- 입금 거래(1) 중 당행 중복이 아닌 것, 혹은 타행 거래
    SELECT  
    
	cnprtacnotype as acnotype, cnprtacno as acno, cnprtname as acnoname, cnprtbnkcd as acnobnkcd, cnprtbnknm as acnobnknm,
	acnotype as cnprtacnotype, acno as cnprtacno, acnoname as cnprtname, acnobnkcd as cnprtbnkcd, acnobnknm as cnprtbnknm,
    rapdstcd,tranprcssyms_arr,tranamt_arr, sumry_arr, tranuno_arr	
	
	
	FROM tutorial_finance.tmp_amgraph_edg_20250701 WHERE rapdstcd = '1' 
    AND NOT EXISTS (
        SELECT 1 FROM tutorial_finance.tmp_amgraph_edg_20250701_dup_check dup 
        WHERE dup.acno = tutorial_finance.tmp_amgraph_edg_20250701.acno 
        AND dup.tranprcssyms_arr = tutorial_finance.tmp_amgraph_edg_20250701.tranprcssyms_arr
    )
) T ;

CREATE INDEX idx_edg_clr ON tutorial_finance.tmp_amgraph_edg_20250701_clr (acno, cnprtacno);

-- ## 7. 일반 엣지 생성 및 업데이트
-- 그래프 상의 `start_id`, `end_id`를 검색하여 신규 엣지는 생성하고, 기존 엣지는 속성을 병합(Merge)합니다.
-- **레이블**: `egrph{YY}` 사용

SET graph_path TO am_graph;

-- 7.1: Start/End Node ID 매핑
-- 엣지를 생성하기 위해, 현재 엣지 데이터의 양 끝점(Start, End)에 해당하는 그래프 노드의 ID(graphid)를 찾습니다.
DROP TABLE IF EXISTS tutorial_finance.tmp_amgraph_edg_20250701_clr_mapped;
CREATE TABLE tutorial_finance.tmp_amgraph_edg_20250701_clr_mapped AS
SELECT tb.*, v1.id as start_id, v2.id as end_id
from tutorial_finance.tmp_amgraph_edg_20250701_clr tb
LEFT JOIN tutorial_finance.tmp_amgraph_vt_20250701_search v1 
ON tb.acno = v1.properties->>'acno'
and tb.acnotype = v1.properties->>'type'
and tb.acnoname = v1.properties->>'name'
and tb.acnobnkcd = v1.properties->>'bnkcd'
LEFT JOIN tutorial_finance.tmp_amgraph_vt_20250701_search v2 
ON tb.cnprtacno = v2.properties->>'acno' 
and tb.cnprtacnotype = v2.properties->>'type'
and tb.cnprtname = v2.properties->>'name'
and tb.cnprtbnkcd = v2.properties->>'bnkcd' order by acno, cnprtacno;




-- 7.2: 기존 엣지 존재 여부 확인
-- 이미 두 노드 사이에 egrph25 레이블을 가진 엣지가 존재하는지 확인합니다.
-- 존재한다면 해당 엣지의 ID(edge_id)를 가져옵니다.
SET graph_path TO am_graph;
DROP TABLE IF EXISTS tutorial_finance.tmp_amgraph_edg_20250701_target;
CREATE TABLE tutorial_finance.tmp_amgraph_edg_20250701_target AS
SELECT tb.*, id_r as edge_id 
FROM tutorial_finance.tmp_amgraph_edg_20250701_clr_mapped tb
LEFT JOIN (
    LOAD FROM tutorial_finance.tmp_amgraph_edg_20250701_clr_mapped AS ro
    MATCH (a)-[r:egrph25]->(b)
    WHERE id(a) = ro.start_id AND id(b) = ro.end_id
    RETURN  id(r) as id_r, id(a) as start_id , id(b) as end_id
) r_search ON tb.start_id = r_search.start_id and tb.end_id = r_search.end_id  ;

-- 7.3: 신규 엣지 생성
-- [Ref: 5.4.2 Edge Creation]
-- 엣지가 없는 경우(edge_id IS NULL), 새로 생성(CREATE)합니다.
-- start_id와 end_id를 사용하여 인덱스 탐색 없이 바로 노드에 접근, 연결합니다.
SET graph_path TO am_graph;
DROP TABLE IF EXISTS tutorial_finance.tmp_amgraph_edg_20250701_create;
CREATE TABLE tutorial_finance.tmp_amgraph_edg_20250701_create AS
SELECT * FROM tutorial_finance.tmp_amgraph_edg_20250701_target WHERE edge_id IS NULL;
DROP TABLE IF EXISTS tutorial_finance.tmp_amgraph_edg_20250701_update;
CREATE TABLE tutorial_finance.tmp_amgraph_edg_20250701_update AS
SELECT * FROM tutorial_finance.tmp_amgraph_edg_20250701_target WHERE edge_id IS not NULL;


LOAD FROM tutorial_finance.tmp_amgraph_edg_20250701_create AS row
MATCH (v1), (v2) WHERE id(v1) = row.start_id AND id(v2) = row.end_id
CREATE (v1)-[r:egrph25 {
    rapdstcd: row.rapdstcd, 
    tranprcssyms_arr: row.tranprcssyms_arr,
    tranamt_arr: row.tranamt_arr
}]->(v2);

-- 7.4: 기존 엣지 업데이트
-- [Ref: 5.4.3 Edge Property Update]
-- 엣지가 이미 있는 경우(edge_id IS NOT NULL), 기존 엣지의 배열 속성에 오늘 발생한 거래 내역을 추가(Append)합니다.
-- 이를 통해 '단일 엣지' 구조를 유지하면서 '거래 이력(History)'을 누적합니다.
SET graph_path TO am_graph;
LOAD FROM tutorial_finance.tmp_amgraph_edg_20250701_update AS row
MATCH ()-[r:egrph25]->() WHERE id(r) = row.edge_id
SET r.tranprcssyms_arr = r.tranprcssyms_arr + row.tranprcssyms_arr,
    r.tranamt_arr = r.tranamt_arr + row.tranamt_arr;

-- ## 8. 대형 엣지(100UP, Large Edge) 처리
-- 고액 거래(`100UP`) 테이블에 대해 위와 동일한 집계, 중복 제거, 생성 로직을 수행합니다.
-- 단, 대형 엣지는 별도의 레이블 `EGRPH00`을 사용하기도 하며 성능 최적화가 중요합니다.

-- 8.1: 대형 엣지 집계
DROP TABLE IF EXISTS tutorial_finance.tmp_amgraph_edg_100up_20250701;
CREATE TABLE tutorial_finance.tmp_amgraph_edg_100up_20250701 AS
SELECT 
    acnotype, acno, acnoname, acnobnkcd, acnobnknm, cnprtacnotype, cnprtacno, cnprtname, cnprtbnkcd, cnprtbnknm, rapdstcd,
    ARRAY_AGG(tranprcssyms ORDER BY tranprcssyms) as tranprcssyms_arr,
    ARRAY_AGG(tranamt ORDER BY tranprcssyms) as tranamt_arr,
    ARRAY_AGG(sumry ORDER BY tranprcssyms) as sumry_arr,
    ARRAY_AGG(tranuno ORDER BY tranprcssyms) as tranuno_arr
FROM tutorial_finance.tmp_agbtch01_20250701_clr_100up
GROUP BY 1,2,3,4,5,6,7,8,9,10,11;

-- ## 9. 최종 정비 및 시스템 최적화
-- 업데이트로 인해 파편화된 엣지를 정리(`partitioned delete logic`)하고, 통계를 갱신합니다.

-- 9.1: 통계 갱신 (Analyze)
-- [Ref: 5.5 Statistics Update]
-- 대량의 데이터 적재 후에는 반드시 통계 정보를 갱신해야 옵티마이저가 올바른 실행 계획을 수립할 수 있습니다.
SET graph_path TO am_graph;
ANALYZE am_graph.VGRPH00;
ANALYZE am_graph.egrph25;

-- 10 하이브리드 모델 설계 (RDB + GDB)
-- RDBMS 통계 및 집계 & Cypher가 제공하는 직관적인 관계 탐색 

CREATE TABLE IF NOT EXISTS tutorial_finance.agdclr25 
(
    acnotype text COLLATE pg_catalog."default",
    acno text COLLATE pg_catalog."default",
    acnoname text COLLATE pg_catalog."default",
    acnobnkcd text COLLATE pg_catalog."default",
    acnobnknm text COLLATE pg_catalog."default",
    cnprtacno text COLLATE pg_catalog."default",
    cnprtacnotype text COLLATE pg_catalog."default",
    cnprtname text COLLATE pg_catalog."default",
    cnprtbnknm text COLLATE pg_catalog."default",
    cnprtbnkcd text COLLATE pg_catalog."default",
    tranamt bigint,
    tranymd character varying(8) COLLATE pg_catalog."default",
    tranprcssyms character varying(30) COLLATE pg_catalog."default",
    rapdstcd character varying(5) COLLATE pg_catalog."default",
    prdctctrcnth character varying(10) COLLATE pg_catalog."default",
    transerno bigint,
    acncustidnfr character varying(20) COLLATE pg_catalog."default",
    hndinbnkcd character varying(10) COLLATE pg_catalog."default",
    hndinbrncd character varying(10) COLLATE pg_catalog."default",
    sumry character varying(200) COLLATE pg_catalog."default",
    tranuno character varying(50) COLLATE pg_catalog."default"
);

insert into tutorial_finance.agdclr25 
select * from tutorial_finance.tmp_agbtch01_20250701_clr


--CREATE INDEX IF NOT EXISTS agdclr25_idx ON tutorial_finance.agdclr25 (acno, cnprtacno, rapdstcd, tranymd);


