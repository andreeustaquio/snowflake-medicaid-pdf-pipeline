/*
Purpose:
    Different ways to validate the batched extraction.

Important:
    This script is intended for testing and validation purposes only.

    The validation queries in this script are intended to be run after the full document has been parsed and the parsed pages have been batched into the PARSE_PAGE_BATCHES temporary table.

    The queries are in no particular order and can be run in any order. The queries are intended to validate the successful parse of the document, the number of pages parsed, and the contents of the parsed pages.
*/

/*
Session prerequisites:
- Set DATABASE, SCHEMA, and WAREHOUSE before running.

Example:
USE DATABASE <DB_NAME>;
USE SCHEMA <SCHEMA_NAME>;
USE WAREHOUSE <WAREHOUSE_NAME>;
*/

-- Validate successful parse exists by DOCUMENT_ID.
SELECT
    DOCUMENT_ID,
    PARSE_RUN_ID,
    RUN_STATUS,
    PARSED_AT
FROM RAW_PARSE_RESULTS
WHERE DOCUMENT_ID = 1
ORDER BY PARSED_AT DESC;


-- Validate how many pages were parsed and stored in the RAW_PARSE_RESULTS table.
SELECT
    DOCUMENT_ID,
    ARRAY_SIZE(RAW_PARSE_RESPONSE:pages) AS PAGE_COUNT
FROM RAW_PARSE_RESULTS
WHERE DOCUMENT_ID = 1
AND RUN_STATUS = 'SUCCESS';

-- Validate the temporary batch table, create PARSE_PAGE_BATCHES
SELECT
    COUNT(*) AS TOTAL_PAGES,
    MIN(PAGE_NUMBER) AS FIRST_PAGE,
    MAX(PAGE_NUMBER) AS LAST_PAGE
FROM PARSE_PAGE_BATCHES;

-- Validate batches are correct.
SELECT
    BATCH_ID,
    COUNT(*) AS PAGE_COUNT
FROM PARSE_PAGE_BATCHES
GROUP BY BATCH_ID
ORDER BY BATCH_ID;

-- Validate no missing page numbers
SELECT
    PAGE_NUMBER
FROM PARSE_PAGE_BATCHES
ORDER BY PAGE_NUMBER;


-- Check the latest extraction results for the first batch of pages (BATCH_ID = 0).
SELECT
    EXTRACT_RUN_ID,
    DOCUMENT_ID,
    PAGE_NUMBER,
    BATCH_ID,
    RUN_STATUS,
    EXTRACTED_AT
FROM RAW_EXTRACTION_RESULTS
WHERE DOCUMENT_ID = 1
ORDER BY EXTRACTED_AT DESC;

-- Inspect first 50 pages
SELECT
    DOCUMENT_ID,
    PARSE_RUN_ID,
    PAGE_NUMBER,
    BATCH_ID
FROM PARSE_PAGE_BATCHES
WHERE BATCH_ID = 0
ORDER BY PAGE_NUMBER;

-- Verify parse source
SELECT
    DOCUMENT_ID,
    PARSE_RUN_ID,
    PARSE_MODE,
    PARSED_AT
FROM RAW_PARSE_RESULTS
WHERE DOCUMENT_ID = 1
AND RUN_STATUS = 'SUCCESS';


-- Validate document level extraction results in RAW_EXTRACTION_RESULTS table.
SELECT
    COUNT(*) AS TOTAL_ROWS,
    COUNT(DISTINCT PAGE_NUMBER) AS UNIQUE_PAGES,
    MIN(PAGE_NUMBER) AS FIRST_PAGE,
    MAX(PAGE_NUMBER) AS LAST_PAGE
FROM RAW_EXTRACTION_RESULTS
WHERE DOCUMENT_ID = 1;
