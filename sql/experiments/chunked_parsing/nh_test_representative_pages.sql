/*
Purpose:
Validate AI_PARSE_DOCUMENT to select the appropriate range of pages from a PDF document before running the full parse across the entire document.

*/
CREATE OR REPLACE TEMP TABLE TEMP_TEST_PARSE AS

SELECT AI_PARSE_DOCUMENT(
    TO_FILE(
        '@MEDICAID_FEE_SCHEDULE_PDFS',
        'NH_FeeSchedule.pdf'
    ),
    {
        'mode': 'LAYOUT',
        'page_filter': [
            {'start': 0, 'end': 100}
        ]
    },
    TRUE
) AS PARSE_OUTPUT;


-- Check for errors in the parse output
SELECT
    PARSE_OUTPUT:error AS PARSE_ERROR,
    PARSE_OUTPUT:metadata AS METADATA
FROM TEMP_TEST_PARSE;


-- Validate the filtered range of pages parsed and stored in the temporary table.
SELECT
    MIN(PAGE.value:index::NUMBER) AS FIRST_PAGE,
    MAX(PAGE.value:index::NUMBER) AS LAST_PAGE,
    COUNT(*) AS PARSED_PAGE_COUNT
FROM TEMP_TEST_PARSE,
LATERAL FLATTEN(
    INPUT => PARSE_OUTPUT:value:pages
) PAGE;

SELECT
    PARSE_OUTPUT:metadata:pageCount::NUMBER AS DOCUMENT_PAGE_COUNT,
    ARRAY_SIZE(PARSE_OUTPUT:value:pages) AS PARSED_PAGE_COUNT
FROM TEMP_TEST_PARSE;

-- Inspect parsed content
SELECT
    PAGE.value:index::NUMBER AS PAGE_INDEX,
    PAGE.value:content::VARCHAR AS PAGE_CONTENT
FROM TEMP_TEST_PARSE,
LATERAL FLATTEN(
    INPUT => PARSE_OUTPUT:value:pages
) PAGE
ORDER BY PAGE_INDEX;

/* 
   Flatten page to review the content of stored result.
*/

SELECT
    PAGE.VALUE:index::NUMBER AS PAGE_INDEX,
    PAGE.VALUE:content::VARCHAR AS PAGE_CONTENT
FROM TEMP_TEST_PARSE,
LATERAL FLATTEN(
    INPUT => PARSE_OUTPUT:value:pages
) PAGE
ORDER BY PAGE_INDEX;

SELECT
    PAGE.VALUE:index::NUMBER AS PAGE_INDEX,
    PAGE.VALUE:content::VARCHAR AS PAGE_CONTENT
FROM TEMP_TEST_PARSE,
LATERAL FLATTEN(
    INPUT => PARSE_OUTPUT:value:pages
) PAGE
ORDER BY PAGE_INDEX;


SELECT
    PARSE_OUTPUT:error AS PARSE_ERROR,
    PARSE_OUTPUT:value AS PARSED_VALUE,
    PARSE_OUTPUT:metadata AS METADATA
FROM TEMP_TEST_PARSE;

SELECT PARSE_OUTPUT
FROM TEMP_TEST_PARSE;

-- Inspect specific pages
SELECT
    PAGE.value:index::NUMBER AS PAGE_NUMBER,
    PAGE.value:content::VARCHAR AS PAGE_TEXT
FROM TEMP_TEST_PARSE,
LATERAL FLATTEN(
    INPUT => PARSE_OUTPUT:value:pages
) PAGE
WHERE PAGE.value:index::NUMBER IN (0, 25, 50, 75, 99)
ORDER BY PAGE_NUMBER;
