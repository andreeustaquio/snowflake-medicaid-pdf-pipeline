/*
Purpose:
    Extract structured fee schedule fields from the full content.

    NM Medicaid fee schedule schema specific.

Process:
  1: Check successful extraction results already stored for this document/parse/version
  2: Check source pages exist for this document/parse run
  3: Show pages still needing extraction
  4: Run original AI_EXTRACT + INSERT only for missing successful pages
  5: Validate results after extraction

Objects:
    Source stage: MEDICAID_FEE_SCHEDULE_PDFS
*/

/*
Session prerequisites:
Run 00_config.sql to set DATABASE, SCHEMA, and WAREHOUSE, parameters, and stage name before running this script.
*/

/* NM 8-column schema */
SET RESPONSE_FORMAT_JSON_NM = '
{
  "schema": {
    "type": "object",
    "properties": {
      "fee_schedule": {
        "type": "object",
        "description": "Main Medicaid reimbursement table. Treat every source table row as a separate independent record, including consecutive rows with the same procedure code. All arrays must contain one element per source row and remain exactly index-aligned. Never move a value between columns, suppress duplicate procedure codes, or treat repeated procedure codes as continuations or modifiers.",
        "column_ordering": [
          "cpt_code",
          "tax",
          "rate",
          "pricing_note",
          "vfc",
          "modifier",
          "rate_2",
          "price_start_date"
        ],
        "properties": {    
          "cpt_code": {
            "type": "array",
            "description": "CPT Code."
          },
          "tax": {
            "type": "array",
            "description": "Tax."
          },
          "rate": {
            "type": "array",
            "description": "Rate."
          },
            "pricing_note": {
                "type": "array",
                "description": "Pricing Note."
            },
            "vfc": {
                "type": "array",
                "description": "VFC."
            },
            "modifier": {
                "type": "array",
                "description": "Modifier."
            },
            "rate_2": {
                "type": "array",
                "description": "Rate 2."
            },
            "price_start_date": {
                "type": "array",
                "description": "Price Start Date."
            }
          }
        }
      }
    }
}';


/*  Step 1:
    Check successful extraction results already stored for this matching document/parse/batch/extraction version before running AI_EXTRACT.
    If there are rows returned, these pages will not be extracted again.
*/
SELECT
    COUNT(*) AS EXISTING_SUCCESSFUL_RESULTS
FROM RAW_EXTRACTION_RESULTS
WHERE DOCUMENT_ID = $DOCUMENT_ID
  AND PARSE_RUN_ID = $PARSE_RUN_ID
  AND SCHEMA_VERSION = $SCHEMA_VERSION
  AND EXTRACTION_VERSION = $EXTRACTION_VERSION
  AND RUN_STATUS = 'SUCCESS';


/* Step 2:
   Create a temporary table with the pages to be extracted.
*/
CREATE OR REPLACE TEMP TABLE TEMP_PARSE_PAGES AS
SELECT
    PARSE.DOCUMENT_ID,
    PARSE.PARSE_RUN_ID,

    PAGE.VALUE:index::NUMBER + 1 AS PAGE_NUMBER,  -- Adjust for 0-based index from FLATTEN to 1-based page number
    PAGE.VALUE:content::VARCHAR AS PAGE_TEXT

FROM RAW_PARSE_RESULTS AS PARSE,

LATERAL FLATTEN(
    INPUT => COALESCE(
        PARSE.RAW_PARSE_RESPONSE:value:pages,
        PARSE.RAW_PARSE_RESPONSE:pages
    )
) AS PAGE

WHERE PARSE.DOCUMENT_ID = $DOCUMENT_ID
  AND PARSE.PARSE_RUN_ID = $PARSE_RUN_ID
  AND PARSE.RUN_STATUS = 'SUCCESS';


-- Check the number of pages in the temporary table.
SELECT
    COUNT(*) AS PAGE_COUNT
FROM TEMP_PARSE_PAGES;



/* Step 3:
  Show pages still needing extraction. 
*/
SELECT
    CASE
        WHEN COUNT(*) = 0
            THEN 'ALL_PAGES_ALREADY_EXTRACTED'
        ELSE 'PAGES_REQUIRE_EXTRACTION'
    END AS EXTRACTION_DECISION,

    COUNT(*) AS PAGES_REQUIRING_EXTRACTION

FROM TEMP_PARSE_PAGES AS p

WHERE NOT EXISTS (
    SELECT 1
    FROM RAW_EXTRACTION_RESULTS AS r
    WHERE r.DOCUMENT_ID = p.DOCUMENT_ID
      AND r.PARSE_RUN_ID = p.PARSE_RUN_ID
      AND r.PAGE_NUMBER = p.PAGE_NUMBER
      AND r.SCHEMA_VERSION = $SCHEMA_VERSION
      AND r.EXTRACTION_VERSION = $EXTRACTION_VERSION
      AND r.RUN_STATUS = 'SUCCESS'
);

/* Step 4: Insert new extraction results for pages that have not yet been successfully extracted.
*/
INSERT INTO RAW_EXTRACTION_RESULTS
(
    DOCUMENT_ID,
    PARSE_RUN_ID,
    PAGE_NUMBER,
    EXTRACTION_VERSION,
    INPUT_TYPE,
    SCORES_REQUESTED,
    RESPONSE_FORMAT,
    SCHEMA_VERSION,
    EXTRACTION_CONFIDENCE,
    RAW_EXTRACTION_RESPONSE,
    RUN_STATUS,
    ERROR_MESSAGE
)

WITH EXTRACTION_RESULTS AS (
    SELECT
        p.DOCUMENT_ID,
        p.PARSE_RUN_ID,
        p.PAGE_NUMBER,

        AI_EXTRACT(
            text => p.PAGE_TEXT,
            responseFormat => PARSE_JSON($RESPONSE_FORMAT_JSON_NM),
            scores => TRUE
        ) AS RAW_EXTRACTION_RESPONSE

    FROM TEMP_PARSE_PAGES AS p
    WHERE NOT EXISTS (
          SELECT 1
          FROM RAW_EXTRACTION_RESULTS AS r
          WHERE r.DOCUMENT_ID = p.DOCUMENT_ID
            AND r.PARSE_RUN_ID = p.PARSE_RUN_ID
            AND r.PAGE_NUMBER = p.PAGE_NUMBER
            AND r.SCHEMA_VERSION = $SCHEMA_VERSION
            AND r.EXTRACTION_VERSION = $EXTRACTION_VERSION
            AND r.RUN_STATUS = 'SUCCESS'
      )
)
SELECT
    DOCUMENT_ID,
    PARSE_RUN_ID,
    PAGE_NUMBER,
    $EXTRACTION_VERSION,
    'TEXT',
    TRUE,
    PARSE_JSON($RESPONSE_FORMAT_JSON_NM),
    $SCHEMA_VERSION,
    RAW_EXTRACTION_RESPONSE
        :scoring:scores:fee_schedule:score::FLOAT
        AS EXTRACTION_CONFIDENCE,

    RAW_EXTRACTION_RESPONSE,
    CASE
        WHEN RAW_EXTRACTION_RESPONSE:error IS NOT NULL
             AND NOT IS_NULL_VALUE(RAW_EXTRACTION_RESPONSE:error)
            THEN 'FAILED'
        ELSE 'SUCCESS'
    END AS RUN_STATUS,

    CASE
        WHEN RAW_EXTRACTION_RESPONSE:error IS NOT NULL
             AND NOT IS_NULL_VALUE(RAW_EXTRACTION_RESPONSE:error)
            THEN RAW_EXTRACTION_RESPONSE:error::VARCHAR
        ELSE NULL
    END AS ERROR_MESSAGE
FROM EXTRACTION_RESULTS;


/* Step 5:
   Quick validation checks after INSERT.
*/

-- 5.1 Summary: extraction outcome and confidence band.
SELECT
    COUNT(*) AS TOTAL_RESULTS,
    COUNT_IF(RUN_STATUS = 'SUCCESS') AS SUCCESSFUL_RESULTS,
    COUNT_IF(RUN_STATUS = 'FAILED') AS FAILED_RESULTS,
    COUNT_IF(
        RUN_STATUS = 'SUCCESS'
        AND (
            EXTRACTION_CONFIDENCE IS NULL
            OR EXTRACTION_CONFIDENCE < $CONFIDENCE_THRESHOLD
        )
    ) AS SUCCESS_REQUIRING_REVIEW,
    MIN(EXTRACTION_CONFIDENCE) AS MIN_CONFIDENCE,
    AVG(EXTRACTION_CONFIDENCE) AS AVG_CONFIDENCE,
    CASE
        WHEN COUNT_IF(RUN_STATUS = 'FAILED') > 0
            THEN 'FAILED_EXTRACTIONS_FOUND'
        WHEN COUNT_IF(
                RUN_STATUS = 'SUCCESS'
                AND (
                    EXTRACTION_CONFIDENCE IS NULL
                    OR EXTRACTION_CONFIDENCE < $CONFIDENCE_THRESHOLD
                )
             ) > 0
            THEN 'REVIEW_LOW_CONFIDENCE_SUCCESS'
        ELSE 'PASS'
    END AS QUICK_STATUS
FROM RAW_EXTRACTION_RESULTS
WHERE DOCUMENT_ID = $DOCUMENT_ID
  AND PARSE_RUN_ID = $PARSE_RUN_ID
  AND EXTRACTION_VERSION = $EXTRACTION_VERSION
  AND SCHEMA_VERSION = $SCHEMA_VERSION;


-- 5.2 Page coverage: expected parsed pages versus extracted result pages.
SELECT
    (SELECT COUNT(*) FROM TEMP_PARSE_PAGES) AS EXPECTED_PAGES,
    COUNT(DISTINCT RESULT.PAGE_NUMBER) AS RESULT_PAGES,
    COUNT(DISTINCT IFF(RESULT.RUN_STATUS = 'SUCCESS', RESULT.PAGE_NUMBER, NULL)) AS SUCCESS_PAGES,
    (
        SELECT COUNT(*)
        FROM TEMP_PARSE_PAGES AS P
        WHERE NOT EXISTS (
            SELECT 1
            FROM RAW_EXTRACTION_RESULTS AS R
            WHERE R.DOCUMENT_ID = P.DOCUMENT_ID
              AND R.PARSE_RUN_ID = P.PARSE_RUN_ID
              AND R.PAGE_NUMBER = P.PAGE_NUMBER
              AND R.EXTRACTION_VERSION = $EXTRACTION_VERSION
              AND R.SCHEMA_VERSION = $SCHEMA_VERSION
        )
    ) AS MISSING_RESULT_PAGES
FROM RAW_EXTRACTION_RESULTS AS RESULT
WHERE RESULT.DOCUMENT_ID = $DOCUMENT_ID
  AND RESULT.PARSE_RUN_ID = $PARSE_RUN_ID
  AND RESULT.EXTRACTION_VERSION = $EXTRACTION_VERSION
  AND RESULT.SCHEMA_VERSION = $SCHEMA_VERSION;


-- 5.3 Failed pages and reason.
WITH FAILED_RESULTS AS (
    SELECT
        PAGE_NUMBER,
        RUN_STATUS,
        EXTRACTION_CONFIDENCE,
        ERROR_MESSAGE
    FROM RAW_EXTRACTION_RESULTS
    WHERE DOCUMENT_ID = $DOCUMENT_ID
      AND PARSE_RUN_ID = $PARSE_RUN_ID
      AND EXTRACTION_VERSION = $EXTRACTION_VERSION
      AND SCHEMA_VERSION = $SCHEMA_VERSION
      AND RUN_STATUS = 'FAILED'
)
SELECT
    CASE
        WHEN COUNT(*) = 0 THEN 'NO_FAILED_PAGES'
        ELSE 'FAILED_PAGES_FOUND'
    END AS FAILED_PAGE_STATUS,
    COUNT(*) AS FAILED_PAGE_COUNT,
    COALESCE(
        LISTAGG(PAGE_NUMBER::VARCHAR, ', ')
            WITHIN GROUP (ORDER BY PAGE_NUMBER),
        'NONE'
    ) AS FAILED_PAGE_LIST
FROM FAILED_RESULTS;


-- 5.3b Detailed failed-page rows.
WITH FAILED_RESULTS AS (
    SELECT
        PAGE_NUMBER,
        RUN_STATUS,
        EXTRACTION_CONFIDENCE,
        ERROR_MESSAGE
    FROM RAW_EXTRACTION_RESULTS
    WHERE DOCUMENT_ID = $DOCUMENT_ID
      AND PARSE_RUN_ID = $PARSE_RUN_ID
      AND EXTRACTION_VERSION = $EXTRACTION_VERSION
      AND SCHEMA_VERSION = $SCHEMA_VERSION
      AND RUN_STATUS = 'FAILED'
)
SELECT
    PAGE_NUMBER,
    RUN_STATUS,
    EXTRACTION_CONFIDENCE,
    ERROR_MESSAGE
FROM FAILED_RESULTS

UNION ALL

SELECT
    NULL AS PAGE_NUMBER,
    'NO_FAILED_PAGES' AS RUN_STATUS,
    NULL AS EXTRACTION_CONFIDENCE,
    'No failed extraction rows for this document/parse/version.' AS ERROR_MESSAGE
WHERE NOT EXISTS (
    SELECT 1
    FROM FAILED_RESULTS
)

ORDER BY PAGE_NUMBER;


-- 5.4 Pages needing review: easy-to-read extraction arrays and raw JSON.
CREATE OR REPLACE TEMP TABLE TEMP_REVIEW_PAGES AS
SELECT DISTINCT
  PAGE_NUMBER
FROM RAW_EXTRACTION_RESULTS
WHERE DOCUMENT_ID = $DOCUMENT_ID
  AND PARSE_RUN_ID = $PARSE_RUN_ID
  AND EXTRACTION_VERSION = $EXTRACTION_VERSION
  AND SCHEMA_VERSION = $SCHEMA_VERSION
  AND (
    RUN_STATUS = 'FAILED'
    OR EXTRACTION_CONFIDENCE IS NULL
    OR EXTRACTION_CONFIDENCE < $CONFIDENCE_THRESHOLD
  );

SELECT COUNT(*) AS review_pages FROM TEMP_REVIEW_PAGES;

-- Will return no results if all pages are successful and above the confidence threshold.
SELECT
  R.PAGE_NUMBER,
  R.RUN_STATUS,
  R.EXTRACTION_CONFIDENCE,
  R.RAW_EXTRACTION_RESPONSE:response:fee_schedule:cpt_code AS CPT_CODE_ARRAY,
  R.RAW_EXTRACTION_RESPONSE:response:fee_schedule:tax AS TAX_ARRAY,
  R.RAW_EXTRACTION_RESPONSE:response:fee_schedule:rate AS RATE_ARRAY,
  R.RAW_EXTRACTION_RESPONSE:response:fee_schedule:pricing_note AS PRICING_NOTE_ARRAY,
  R.RAW_EXTRACTION_RESPONSE:response:fee_schedule:vfc AS VFC_ARRAY,
  R.RAW_EXTRACTION_RESPONSE:response:fee_schedule:modifier AS MODIFIER_ARRAY,
  R.RAW_EXTRACTION_RESPONSE:response:fee_schedule:rate_2 AS RATE_2_ARRAY,
  R.RAW_EXTRACTION_RESPONSE:response:fee_schedule:price_start_date AS PRICE_START_DATE_ARRAY,
  R.RAW_EXTRACTION_RESPONSE
FROM RAW_EXTRACTION_RESULTS AS R
INNER JOIN TEMP_REVIEW_PAGES AS P
  ON R.PAGE_NUMBER = P.PAGE_NUMBER
WHERE R.DOCUMENT_ID = $DOCUMENT_ID
  AND R.PARSE_RUN_ID = $PARSE_RUN_ID
  AND R.EXTRACTION_VERSION = $EXTRACTION_VERSION
  AND R.SCHEMA_VERSION = $SCHEMA_VERSION
ORDER BY R.PAGE_NUMBER, R.EXTRACTION_RESULT_ID;


SELECT
  COUNT(*) AS total_pages,
  COUNT_IF(RUN_STATUS = 'FAILED') AS failed_pages,
  COUNT_IF(EXTRACTION_CONFIDENCE IS NULL) AS null_confidence_pages,
  COUNT_IF(EXTRACTION_CONFIDENCE < $CONFIDENCE_THRESHOLD) AS low_conf_pages
FROM RAW_EXTRACTION_RESULTS
WHERE DOCUMENT_ID = $DOCUMENT_ID
  AND PARSE_RUN_ID = $PARSE_RUN_ID
  AND EXTRACTION_VERSION = $EXTRACTION_VERSION
  AND SCHEMA_VERSION = $SCHEMA_VERSION;


-- 5.5 Optional helper: inspect parsed page text for review pages.
-- Replace the IN () list with page numbers from Step 5.4 
SELECT
  P.PAGE_NUMBER,
  P.PAGE_TEXT
FROM TEMP_PARSE_PAGES AS P
WHERE P.PAGE_NUMBER IN (322)
ORDER BY P.PAGE_NUMBER;
