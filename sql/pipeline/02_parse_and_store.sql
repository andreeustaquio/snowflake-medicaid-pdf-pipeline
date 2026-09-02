/*
Purpose:
    Parse and store the full Medicaid fee schedule only when a
    matching successful parse does not already exist.

Process:
    1. Confirm that the source file exists in the stage.
    2. Find the registry record matching the current file version.
    3. Determine whether parsing is required and report the reason.
    4. Select the document only when it is ready to parse.
    5. Parse the full document and run pre-insert validation checks.
    6. Store the raw response and classify the parse result.
    7. Report the latest stored parse attempt.
    8. Confirm the latest successful parse available for extraction.

Important:
    If the exact current file version already has a matching
    successful parse, TEMP_DOCUMENT_TO_PARSE contains zero rows
    and AI_PARSE_DOCUMENT is skipped.

    PARSE_DECISION explains why the document is or is not selected
    for parsing.
*/


/*
Session prerequisites:
Run 00_config.sql to set DATABASE, SCHEMA, and WAREHOUSE, parameters, and stage name before running this script.
*/

/* Step 1:
   Confirm that the current Medicaid source file exists in the stage.
*/

ALTER STAGE MEDICAID_FEE_SCHEDULE_PDFS REFRESH;

CREATE OR REPLACE TEMP TABLE TEMP_STAGE_FILE AS
SELECT
    D.RELATIVE_PATH,
    SPLIT_PART(D.RELATIVE_PATH, '/', -1) AS FILE_NAME,
    D.SIZE,
    D.LAST_MODIFIED,
    D.MD5
FROM DIRECTORY(@MEDICAID_FEE_SCHEDULE_PDFS) AS D
WHERE D.RELATIVE_PATH = $FILE_NAME;


/* Step 2:
    Find the registry record matching the exact file currently
   present in the stage, selected in the previous step.
*/

CREATE OR REPLACE TEMP TABLE TEMP_DOCUMENT AS
SELECT
    DOCUMENT_ID,
    RELATIVE_PATH,
    FILE_NAME,
    FILE_MD5
FROM CTL_DOCUMENT_REGISTRY
WHERE DOCUMENT_ID = $DOCUMENT_ID;


/* Step 3:
   Report why the document will or will not be parsed.
*/

CREATE OR REPLACE TEMP TABLE TEMP_PARSE_DECISION AS
SELECT
    CASE
        WHEN (SELECT COUNT(*) FROM TEMP_STAGE_FILE) = 0
            THEN 'SOURCE_FILE_MISSING'

        WHEN (SELECT COUNT(*) FROM TEMP_STAGE_FILE) > 1
            THEN 'MULTIPLE_STAGE_MATCHES'

        WHEN (SELECT COUNT(*) FROM TEMP_DOCUMENT) = 0
            THEN 'DOCUMENT_NOT_REGISTERED'

        WHEN (SELECT COUNT(*) FROM TEMP_DOCUMENT) > 1
            THEN 'DUPLICATE_REGISTRY_MATCHES'

        WHEN EXISTS (
            SELECT 1
            FROM RAW_PARSE_RESULTS AS PARSE_HISTORY
            INNER JOIN TEMP_DOCUMENT AS DOCUMENT
                ON PARSE_HISTORY.DOCUMENT_ID = DOCUMENT.DOCUMENT_ID
            WHERE PARSE_HISTORY.PARSE_VERSION = $PARSE_VERSION
              AND PARSE_HISTORY.PARSE_MODE = $PARSE_MODE
              AND PARSE_HISTORY.PARSE_CONFIG:page_split::BOOLEAN = TRUE
              AND PARSE_HISTORY.RUN_STATUS = $RUN_STATUS
        )
            THEN 'ALREADY_PARSED_SUCCESSFULLY'

        ELSE 'READY_TO_PARSE'
    END AS PARSE_DECISION;


SELECT
    DECISION.PARSE_DECISION,
    (SELECT COUNT(*) FROM TEMP_STAGE_FILE)
        AS STAGE_FILE_COUNT,
    (SELECT COUNT(*) FROM TEMP_DOCUMENT)
        AS REGISTERED_DOCUMENT_COUNT,
    (
        SELECT COUNT(*)
        FROM RAW_PARSE_RESULTS AS PARSE_HISTORY
        INNER JOIN TEMP_DOCUMENT AS DOCUMENT
            ON PARSE_HISTORY.DOCUMENT_ID = DOCUMENT.DOCUMENT_ID
        WHERE PARSE_HISTORY.PARSE_VERSION = $PARSE_VERSION
          AND PARSE_HISTORY.PARSE_MODE = $PARSE_MODE
          AND PARSE_HISTORY.PARSE_CONFIG:page_split::BOOLEAN = TRUE
          AND PARSE_HISTORY.RUN_STATUS = $RUN_STATUS
    ) AS SUCCESSFUL_PARSE_COUNT,
    (SELECT MAX(DOCUMENT_ID) FROM TEMP_DOCUMENT)
        AS DOCUMENT_ID
FROM TEMP_PARSE_DECISION AS DECISION;


/* Step 4:
   Select the document only when the explicit decision is
   READY_TO_PARSE.
*/

CREATE OR REPLACE TEMP TABLE TEMP_DOCUMENT_TO_PARSE AS
SELECT
    DOCUMENT.DOCUMENT_ID,
    DOCUMENT.RELATIVE_PATH,
    DOCUMENT.FILE_NAME
FROM TEMP_DOCUMENT AS DOCUMENT
CROSS JOIN TEMP_PARSE_DECISION AS DECISION
WHERE DECISION.PARSE_DECISION = 'READY_TO_PARSE';


SELECT
    DECISION.PARSE_DECISION,
    COUNT(DOCUMENT.DOCUMENT_ID) AS DOCUMENTS_TO_PARSE
FROM TEMP_PARSE_DECISION AS DECISION
LEFT JOIN TEMP_DOCUMENT_TO_PARSE AS DOCUMENT
    ON TRUE
GROUP BY DECISION.PARSE_DECISION;


/* Step 5:
   Parse the full document only when Step 4 selected a row.

   The final TRUE returns the parsed value, error details,
   and document metadata.

   If TEMP_DOCUMENT_TO_PARSE is empty, the parse is skipped.
*/

CREATE OR REPLACE TEMP TABLE TEMP_FULL_PARSE AS
SELECT
    DOCUMENT.DOCUMENT_ID,

    AI_PARSE_DOCUMENT(
        TO_FILE(
            '@MEDICAID_FEE_SCHEDULE_PDFS',
            DOCUMENT.RELATIVE_PATH
        ),
        {
            'mode': $PARSE_MODE,
            'page_split': TRUE
        },
        TRUE
    ) AS RAW_PARSE_RESPONSE

FROM TEMP_DOCUMENT_TO_PARSE AS DOCUMENT;


/* Step 5b:
   Validate parse output before inserting into RAW_PARSE_RESULTS.

   This lets you inspect the raw parse response and confirm whether
   the parse function returned an error.
   
   Option A: Run DURING a parse execution (reads TEMP_FULL_PARSE).
   Option B: Run INDEPENDENTLY on existing parses (reads RAW_PARSE_RESULTS).
   
   For Option B, just replace the table reference below.
*/

-- 5b.1 Parse status summary before insert.
-- Use during Step 5 execution (TEMP_FULL_PARSE exists).
SELECT
    COUNT(*) AS PARSE_ROWS_RETURNED,
    COUNT_IF(
        RAW_PARSE_RESPONSE:error IS NOT NULL
        AND NOT IS_NULL_VALUE(RAW_PARSE_RESPONSE:error)
    ) AS PARSE_ERROR_ROWS,
    CASE
        WHEN COUNT(*) = 0
            THEN 'NO_PARSE_OUTPUT'
        WHEN COUNT_IF(
                RAW_PARSE_RESPONSE:error IS NOT NULL
                AND NOT IS_NULL_VALUE(RAW_PARSE_RESPONSE:error)
             ) > 0
            THEN 'PARSE_ERROR_FOUND'
        ELSE 'PARSE_OUTPUT_READY'
    END AS PRE_INSERT_PARSE_STATUS
FROM TEMP_FULL_PARSE;


-- 5b.2 Parse metadata and page count check.
-- Run independently on existing parse: change TEMP_FULL_PARSE to RAW_PARSE_RESULTS.
SELECT
    DOCUMENT_ID,
    COALESCE(
        RAW_PARSE_RESPONSE:metadata:pageCount::NUMBER,
        RAW_PARSE_RESPONSE:value:metadata:pageCount::NUMBER
    ) AS EXPECTED_PAGE_COUNT,
    COALESCE(
        ARRAY_SIZE(RAW_PARSE_RESPONSE:value:pages),
        ARRAY_SIZE(RAW_PARSE_RESPONSE:pages)
    ) AS ACTUAL_PAGE_ARRAY_SIZE,
    RAW_PARSE_RESPONSE:error AS PARSE_ERROR
FROM TEMP_FULL_PARSE;


-- 5b.3 Sample first page content and structure.
-- Run independently on existing parse: change TEMP_FULL_PARSE to RAW_PARSE_RESULTS.
WITH PARSED_PAGES AS (
    SELECT
        P.DOCUMENT_ID,
        PAGE.VALUE:index::NUMBER + 1 AS PAGE_NUMBER,
        PAGE.VALUE:content::VARCHAR AS PAGE_CONTENT,
        LENGTH(PAGE.VALUE:content::VARCHAR) AS CONTENT_LENGTH
    FROM TEMP_FULL_PARSE AS P,
    LATERAL FLATTEN(
        INPUT => COALESCE(
            P.RAW_PARSE_RESPONSE:value:pages,
            P.RAW_PARSE_RESPONSE:pages
        )
    ) AS PAGE
)
SELECT
    DOCUMENT_ID,
    PAGE_NUMBER,
    CONTENT_LENGTH,
    PAGE_CONTENT
FROM PARSED_PAGES
WHERE PAGE_NUMBER = 1;


-- 5b.4 Full raw parse response and parsed error field.
-- Run independently on existing parse: change TEMP_FULL_PARSE to RAW_PARSE_RESULTS.
SELECT
    DOCUMENT_ID,
    RAW_PARSE_RESPONSE:error AS PARSE_ERROR,
    RAW_PARSE_RESPONSE
FROM TEMP_FULL_PARSE;


/* Step 5c:
   Parse quality check: inspect page text for column structure clarity.
   
   This runs INDEPENDENTLY after parse is stored.
   You do NOT need to re-run the entire file.
   Just run this query alone to check if pages show clear table structure
   or merged/ambiguous column layout.
*/


-- 5c.1 Sample quality metrics for first 3 pages.
WITH PARSED_PAGES AS (
  SELECT
    P.DOCUMENT_ID,
    -- P.PARSE_RUN_ID,
    PAGE.VALUE:index::NUMBER + 1 AS PAGE_NUMBER,
    PAGE.VALUE:content::VARCHAR AS PAGE_TEXT,
    LENGTH(PAGE.VALUE:content::VARCHAR) AS TEXT_LENGTH,
    
    -- Count consecutive spaces (indicator of column alignment)
    (LENGTH(PAGE.VALUE:content::VARCHAR) - LENGTH(REPLACE(PAGE.VALUE:content::VARCHAR, '  ', ''))) AS DOUBLE_SPACE_COUNT,
    
    -- Count line breaks (indicator of row structure)
    (LENGTH(PAGE.VALUE:content::VARCHAR) - LENGTH(REPLACE(PAGE.VALUE:content::VARCHAR, CHAR(10), ''))) AS LINE_BREAK_COUNT
    
  FROM TEMP_FULL_PARSE AS P,
  LATERAL FLATTEN(
    INPUT => COALESCE(
      P.RAW_PARSE_RESPONSE:value:pages,
      P.RAW_PARSE_RESPONSE:pages
    )
  ) AS PAGE
  WHERE P.DOCUMENT_ID = $DOCUMENT_ID
    -- AND P.PARSE_VERSION = $PARSE_VERSION
    -- AND P.RUN_STATUS = 'SUCCESS'
)
SELECT
  PAGE_NUMBER,
  TEXT_LENGTH,
  DOUBLE_SPACE_COUNT,
  LINE_BREAK_COUNT,
  ROUND(DOUBLE_SPACE_COUNT * 100.0 / NULLIF(TEXT_LENGTH, 0), 2) AS SPACING_DENSITY_PCT,
  IFF(DOUBLE_SPACE_COUNT < 5, 'POSSIBLY_MERGED_COLUMNS', 'LIKELY_CLEAN_STRUCTURE') AS STRUCTURE_QUALITY,
  PAGE_TEXT
FROM PARSED_PAGES
WHERE PAGE_NUMBER <= 3
ORDER BY PAGE_NUMBER;


-- 5c.2 Check specific pages if you have flagged page numbers.
-- Uncomment and replace (521, 552, 638) with your actual flagged pages.

WITH PARSED_PAGES AS (
  SELECT
    PAGE.VALUE:index::NUMBER + 1 AS PAGE_NUMBER,
    PAGE.VALUE:content::VARCHAR AS PAGE_TEXT,
    LENGTH(PAGE.VALUE:content::VARCHAR) AS TEXT_LENGTH,
    (LENGTH(PAGE.VALUE:content::VARCHAR) - LENGTH(REPLACE(PAGE.VALUE:content::VARCHAR, '  ', ''))) AS DOUBLE_SPACE_COUNT,
    (LENGTH(PAGE.VALUE:content::VARCHAR) - LENGTH(REPLACE(PAGE.VALUE:content::VARCHAR, CHAR(10), ''))) AS LINE_BREAK_COUNT
  FROM TEMP_FULL_PARSE AS P,
  LATERAL FLATTEN(
    INPUT => COALESCE(
      P.RAW_PARSE_RESPONSE:value:pages,
      P.RAW_PARSE_RESPONSE:pages
    )
  ) AS PAGE
  WHERE P.DOCUMENT_ID = $DOCUMENT_ID
    -- AND P.PARSE_VERSION = $PARSE_VERSION
    -- AND P.RUN_STATUS = 'SUCCESS'
)
SELECT
  PAGE_NUMBER,
  TEXT_LENGTH,
  DOUBLE_SPACE_COUNT,
  LINE_BREAK_COUNT,
  ROUND(DOUBLE_SPACE_COUNT * 100.0 / NULLIF(TEXT_LENGTH, 0), 2) AS SPACING_DENSITY_PCT,
  IFF(DOUBLE_SPACE_COUNT < 5, 'POSSIBLY_MERGED_COLUMNS', 'LIKELY_CLEAN_STRUCTURE') AS STRUCTURE_QUALITY,
  PAGE_TEXT
FROM PARSED_PAGES
-- WHERE PAGE_NUMBER IN (521, 552, 638)
ORDER BY PAGE_NUMBER;



/* Step 6:
    Store the raw parse response and validated run status and error message.

   If no parse was required, this inserts zero rows.
*/

INSERT INTO RAW_PARSE_RESULTS (
    DOCUMENT_ID,
    PARSE_VERSION,
    PARSE_MODE,
    PARSE_CONFIG,
    PARSE_METHOD,
    CHUNK_NUMBER,
    RAW_PARSE_RESPONSE,
    RUN_STATUS,
    ERROR_MESSAGE
)
WITH NORMALIZED_PARSE AS (
    SELECT
        PARSE_RESULT.DOCUMENT_ID,
        PARSE_RESULT.RAW_PARSE_RESPONSE,

        COALESCE(
            PARSE_RESULT.RAW_PARSE_RESPONSE:value:pages,
            PARSE_RESULT.RAW_PARSE_RESPONSE:pages
        ) AS PARSED_PAGES,

        COALESCE(
            PARSE_RESULT.RAW_PARSE_RESPONSE:metadata,
            PARSE_RESULT.RAW_PARSE_RESPONSE:value:metadata
        ) AS PARSE_METADATA,

        PARSE_RESULT.RAW_PARSE_RESPONSE:error AS PARSE_ERROR

    FROM TEMP_FULL_PARSE AS PARSE_RESULT
),
EMPTY_PAGE_FLAGS AS (
    SELECT
        PARSE.DOCUMENT_ID,
        IFF(
            COUNT_IF(
                PAGE.VALUE:content IS NULL
                OR TRIM(PAGE.VALUE:content::VARCHAR) = ''
            ) > 0,
            TRUE,
            FALSE
        ) AS HAS_EMPTY_PAGE
    FROM NORMALIZED_PARSE AS PARSE,
    LATERAL FLATTEN(
        INPUT => PARSE.PARSED_PAGES
    ) AS PAGE
    GROUP BY PARSE.DOCUMENT_ID
)
SELECT
    PARSE.DOCUMENT_ID,
    $PARSE_VERSION AS PARSE_VERSION,
    $PARSE_MODE AS PARSE_MODE,

    OBJECT_CONSTRUCT(
        'mode', $PARSE_MODE,
        'page_split', TRUE
    ) AS PARSE_CONFIG,

    'FULL' AS PARSE_METHOD,
    NULL AS CHUNK_NUMBER,

    RAW_PARSE_RESPONSE,

    CASE
        WHEN PARSE_ERROR IS NOT NULL
             AND NOT IS_NULL_VALUE(PARSE_ERROR)
            THEN 'FAILED'

        WHEN COALESCE(ARRAY_SIZE(PARSED_PAGES), 0) = 0
            THEN 'FAILED'

        WHEN PARSE_METADATA:pageCount::NUMBER IS NULL
            THEN 'FAILED'

        WHEN PARSE_METADATA:pageCount::NUMBER
             != ARRAY_SIZE(PARSED_PAGES)
            THEN 'FAILED'

        WHEN COALESCE(EMPTY.HAS_EMPTY_PAGE, FALSE)
            THEN 'FAILED'

        ELSE 'SUCCESS'
    END AS RUN_STATUS,

    CASE
        WHEN PARSE_ERROR IS NOT NULL
             AND NOT IS_NULL_VALUE(PARSE_ERROR)
            THEN PARSE_ERROR::VARCHAR

        WHEN COALESCE(ARRAY_SIZE(PARSED_PAGES), 0) = 0
            THEN 'Parser returned no pages'

        WHEN PARSE_METADATA:pageCount::NUMBER IS NULL
            THEN 'Parser response is missing metadata.pageCount'

        WHEN PARSE_METADATA:pageCount::NUMBER
             != ARRAY_SIZE(PARSED_PAGES)
            THEN 'Metadata page count does not match stored page count'

        WHEN COALESCE(EMPTY.HAS_EMPTY_PAGE, FALSE)
            THEN 'One or more parsed pages are empty'

        ELSE NULL
    END AS ERROR_MESSAGE

FROM NORMALIZED_PARSE AS PARSE
LEFT JOIN EMPTY_PAGE_FLAGS AS EMPTY
    ON PARSE.DOCUMENT_ID = EMPTY.DOCUMENT_ID;



/* Step 7:
    Report the latest stored parse attempt, whether successful or failed.

    If parsing was skipped, this returns the previous latest attempt.
*/

SELECT
    PARSE.PARSE_RUN_ID,
    PARSE.DOCUMENT_ID,
    PARSE.RUN_STATUS,
    PARSE.ERROR_MESSAGE,
    PARSE.PARSED_AT
FROM RAW_PARSE_RESULTS AS PARSE
INNER JOIN TEMP_DOCUMENT AS DOCUMENT
    ON PARSE.DOCUMENT_ID = DOCUMENT.DOCUMENT_ID
WHERE PARSE.PARSE_VERSION = $PARSE_VERSION
  AND PARSE.PARSE_MODE = $PARSE_MODE
  AND PARSE.PARSE_CONFIG:page_split::BOOLEAN = TRUE
ORDER BY PARSE.PARSE_RUN_ID DESC
LIMIT 1;


/* Step 8:
   Confirm the latest successful stored parse available for downstream extraction.

   If the parse was skipped, this returns the existing result.
*/

SELECT
    PARSE.PARSE_RUN_ID,
    PARSE.DOCUMENT_ID,
    PARSE.PARSE_VERSION,
    PARSE.PARSE_MODE,
    PARSE.PARSE_CONFIG,
    COALESCE(
        PARSE.RAW_PARSE_RESPONSE:metadata:pageCount::NUMBER,
        PARSE.RAW_PARSE_RESPONSE:value:metadata:pageCount::NUMBER
    ) AS PAGE_COUNT,
    PARSE.RUN_STATUS,
    PARSE.ERROR_MESSAGE,
    PARSE.PARSED_AT
FROM RAW_PARSE_RESULTS AS PARSE
INNER JOIN TEMP_DOCUMENT AS DOCUMENT
    ON PARSE.DOCUMENT_ID = DOCUMENT.DOCUMENT_ID
WHERE PARSE.PARSE_VERSION = $PARSE_VERSION
  AND PARSE.PARSE_MODE = $PARSE_MODE
  AND PARSE.PARSE_CONFIG:page_split::BOOLEAN = TRUE
  AND PARSE.RUN_STATUS = $RUN_STATUS
ORDER BY PARSE.PARSE_RUN_ID DESC
LIMIT 1;

-- Set the PARSE_RUN_ID for downstream extraction steps.
SET PARSE_RUN_ID = (
    SELECT MAX(PARSE_RUN_ID)
    FROM RAW_PARSE_RESULTS
    WHERE DOCUMENT_ID = $DOCUMENT_ID
      AND PARSE_VERSION = $PARSE_VERSION
      AND PARSE_MODE = $PARSE_MODE
            AND PARSE_CONFIG:page_split::BOOLEAN = TRUE
      AND RUN_STATUS = $RUN_STATUS
);

-- Confirm the parse run selected for downstream steps.
SELECT $PARSE_RUN_ID AS PARSE_RUN_ID;
