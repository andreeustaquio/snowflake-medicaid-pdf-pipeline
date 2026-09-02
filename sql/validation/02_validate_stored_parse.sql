/*
Purpose:
    Validate the latest successful stored full-document parse for the
    ND Medicaid fee schedule without rerunning AI_PARSE_DOCUMENT.

Process:
    1. Find the latest successful ND parse.
    2. Confirm the stored parse metadata and status.
    3. Count stored and empty pages.
    4. Inspect representative stored pages.

Important:
    This script reads RAW_PARSE_RESULTS only.
    It does not perform AI parsing.
*/

/*
Session prerequisites:
- Set DATABASE, SCHEMA, and WAREHOUSE before running.
- Do not hardcode personal dev names in shared SQL.

Example:
USE DATABASE <DB_NAME>;
USE SCHEMA <SCHEMA_NAME>;
USE WAREHOUSE <WAREHOUSE_NAME>;
*/


/* Step 1:
   Store the latest successful ND parse in a temporary table.
*/

CREATE OR REPLACE TEMP TABLE TEMP_LATEST_ND_PARSE AS
SELECT
    PARSE.PARSE_RUN_ID,
    PARSE.DOCUMENT_ID,
    PARSE.PARSE_VERSION,
    PARSE.PARSE_MODE,
    PARSE.RAW_PARSE_RESPONSE,
    PARSE.RUN_STATUS,
    PARSE.ERROR_MESSAGE,
    PARSE.PARSED_AT
FROM RAW_PARSE_RESULTS AS PARSE
INNER JOIN CTL_DOCUMENT_REGISTRY AS DOCUMENT
    ON PARSE.DOCUMENT_ID = DOCUMENT.DOCUMENT_ID
WHERE DOCUMENT.STAGE_NAME = 'MEDICAID_FEE_SCHEDULE_PDFS'
  AND DOCUMENT.FILE_NAME = 'ND_FeeSchedule.pdf'
  AND PARSE.RUN_STATUS = 'SUCCESS'
ORDER BY PARSE.PARSE_RUN_ID DESC
LIMIT 1;


/* Step 2:
   Confirm the stored parse record.
*/

SELECT
    PARSE_RUN_ID,
    DOCUMENT_ID,
    PARSE_VERSION,
    PARSE_MODE,
    RAW_PARSE_RESPONSE:metadata:pageCount::NUMBER AS PAGE_COUNT,
    RUN_STATUS,
    ERROR_MESSAGE,
    PARSED_AT
FROM TEMP_LATEST_ND_PARSE;


/* Step 3:
   Confirm that all pages were stored.
*/

SELECT
    PARSE.PARSE_RUN_ID,
    COUNT(*) AS STORED_PAGE_COUNT,
    COUNT_IF(
        PAGE.VALUE:content::VARCHAR IS NULL
        OR TRIM(PAGE.VALUE:content::VARCHAR) = ''
    ) AS EMPTY_PAGE_COUNT
FROM TEMP_LATEST_ND_PARSE AS PARSE,
LATERAL FLATTEN(
    INPUT => PARSE.RAW_PARSE_RESPONSE:pages
) AS PAGE
GROUP BY PARSE.PARSE_RUN_ID;


/* Step 4:
   Inspect representative stored pages.
*/

SELECT
    PAGE.VALUE:index::NUMBER AS PAGE_INDEX,
    PAGE.VALUE:content::VARCHAR AS PAGE_CONTENT
FROM TEMP_LATEST_ND_PARSE AS PARSE,
LATERAL FLATTEN(
    INPUT => PARSE.RAW_PARSE_RESPONSE:pages
) AS PAGE
WHERE PAGE.VALUE:index::NUMBER IN (0, 160, 180, 321)    -- representative pages to inspect beginning, middle, all columns populated, and end of document
ORDER BY PAGE_INDEX;
