/*
Purpose:
    Parse and store the full Medicaid fee schedule only when a
    matching successful parse does not already exist.
    Checks the page count and splits the document into chunks for parsing if it exceeds a threshold.


Process:
    1. Confirm that the source file exists in the stage.
    2. Find the registry record matching the current file version.
    3. Determine whether parsing is required and report the reason.
    4. Determine whether to parse the full document or split into chunks based on page count threshold.
    5. Parse the full document or each chunk separately.
    6. Store the raw response and classify the parse result. 
        - Flatten the chunked parse results and store one combined parse result.
    7. Report the latest successful parse result for the current document.
    8. Confirm the latest successful parse available for extraction.

Important:
    AI_PARSE_DOCUMENT is the expensive step.

    If the exact current file version already has a matching
    successful parse, TEMP_ND_DOCUMENT_TO_PARSE contains zero rows
    and AI_PARSE_DOCUMENT is skipped.

    PARSE_DECISION explains why the document is or is not selected
    for parsing.
*/


/*
Session prerequisites:
Run 00_config.sql to set DATABASE, SCHEMA, and WAREHOUSE, parameters, and stage name before running this script.
*/


/* Step 1:
   Confirm that the current source file exists in the stage.
*/

SET PARSE_PAGE_THRESHOLD = 150;
SET PARSE_CHUNK_SIZE = 100;

SET DOCUMENT_ID = 201;

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
    FILE_MD5,
    PAGE_COUNT
FROM CTL_DOCUMENT_REGISTRY
WHERE DOCUMENT_ID = $DOCUMENT_ID;


-- Check table contents.
SELECT
    DOCUMENT_ID,
    FILE_NAME,
    PAGE_COUNT
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
   Full versus chunked decision based on page count threshold.
*/
CREATE OR REPLACE TEMP TABLE TEMP_PARSE_METHOD AS
SELECT
    DOCUMENT_ID,
    PAGE_COUNT,

    CASE 
        WHEN PAGE_COUNT <= $PARSE_PAGE_THRESHOLD
            THEN 'FULL'

        ELSE 'CHUNKED'
    END AS PARSE_METHOD
FROM TEMP_DOCUMENT;


-- Check table contents.
SELECT
    DOCUMENT_ID,
    PAGE_COUNT,
    PARSE_METHOD
FROM TEMP_PARSE_METHOD;



/* Step 5A:
   Run the normal full-document parse only for FULL documents.
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

FROM TEMP_DOCUMENT AS DOCUMENT
CROSS JOIN TEMP_PARSE_DECISION AS DECISION
CROSS JOIN TEMP_PARSE_METHOD AS METHOD

WHERE DECISION.PARSE_DECISION = 'READY_TO_PARSE'
  AND METHOD.PARSE_METHOD = 'FULL';



-- Confirm full parse was skipped for CHUNKED documents.
SELECT
    METHOD.PARSE_METHOD,
    CASE
        WHEN COUNT(PARSE.DOCUMENT_ID) = 0
            THEN 'FULL_PARSE_SKIPPED'
        ELSE 'FULL_PARSE_EXECUTED'
    END AS FULL_PARSE_STATUS,
    COUNT(PARSE.DOCUMENT_ID) AS FULL_PARSE_ROWS
FROM TEMP_PARSE_METHOD AS METHOD
LEFT JOIN TEMP_FULL_PARSE AS PARSE
    ON METHOD.DOCUMENT_ID = PARSE.DOCUMENT_ID
GROUP BY METHOD.PARSE_METHOD;


/* Step 5B:
   Build page ranges only for CHUNKED documents.
*/

CREATE OR REPLACE TEMP TABLE TEMP_PARSE_CHUNKS AS
SELECT
    DOCUMENT.DOCUMENT_ID,
    DOCUMENT.RELATIVE_PATH,
    DOCUMENT.FILE_NAME,
    DOCUMENT.PAGE_COUNT,

    CHUNK.VALUE::NUMBER + 1 AS CHUNK_NUMBER,

    CHUNK.VALUE::NUMBER * $PARSE_CHUNK_SIZE
        AS START_PAGE_INDEX,

    LEAST(
        (CHUNK.VALUE::NUMBER + 1) * $PARSE_CHUNK_SIZE,
        DOCUMENT.PAGE_COUNT
    ) AS END_PAGE_INDEX

FROM TEMP_DOCUMENT AS DOCUMENT
CROSS JOIN TEMP_PARSE_DECISION AS DECISION
CROSS JOIN TEMP_PARSE_METHOD AS METHOD,

LATERAL FLATTEN(
    INPUT => ARRAY_GENERATE_RANGE(
        0,
        CEIL(DOCUMENT.PAGE_COUNT / $PARSE_CHUNK_SIZE)
    )
) AS CHUNK

WHERE DECISION.PARSE_DECISION = 'READY_TO_PARSE'
  AND METHOD.PARSE_METHOD = 'CHUNKED';



-- Confirm the chunked parse ranges are correct.
SELECT
    DOCUMENT_ID,
    CHUNK_NUMBER,
    START_PAGE_INDEX,
    END_PAGE_INDEX
FROM TEMP_PARSE_CHUNKS
ORDER BY CHUNK_NUMBER;


/* Step 5C:
   Parse each chunk separately.
*/

CREATE OR REPLACE TEMP TABLE TEMP_CHUNK_PARSE AS
SELECT
    CHUNK.DOCUMENT_ID,
    CHUNK.CHUNK_NUMBER,
    CHUNK.START_PAGE_INDEX,
    CHUNK.END_PAGE_INDEX,

    AI_PARSE_DOCUMENT(
        TO_FILE(
            '@MEDICAID_FEE_SCHEDULE_PDFS',
            CHUNK.RELATIVE_PATH
        ),
        OBJECT_CONSTRUCT(
            'mode', $PARSE_MODE,
            'page_filter',
            ARRAY_CONSTRUCT(
                OBJECT_CONSTRUCT(
                    'start', CHUNK.START_PAGE_INDEX,
                    'end', CHUNK.END_PAGE_INDEX
                )
            )
        ),
        TRUE
    ) AS RAW_PARSE_RESPONSE

FROM TEMP_PARSE_CHUNKS AS CHUNK;



-- Check the results of the chunked parse.
SELECT
    CHUNK_NUMBER,
    START_PAGE_INDEX,
    END_PAGE_INDEX,
    RAW_PARSE_RESPONSE:error AS PARSE_ERROR,
    ARRAY_SIZE(
        COALESCE(
            RAW_PARSE_RESPONSE:value:pages,
            RAW_PARSE_RESPONSE:pages
        )
    ) AS PARSED_PAGE_COUNT,
    RAW_PARSE_RESPONSE
FROM TEMP_CHUNK_PARSE
ORDER BY CHUNK_NUMBER;



/* Step 6:
   If full document parsed, store the raw parse response and validated run status and error message.

   If no parse was required, including chunked document parses, this inserts zero rows.
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
)
SELECT
    DOCUMENT_ID,
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

        ELSE NULL
    END AS ERROR_MESSAGE

FROM NORMALIZED_PARSE;



/* Step 6A:
   Flatten pages returned from each chunk.
*/

CREATE OR REPLACE TEMP TABLE TEMP_CHUNK_PAGES AS
SELECT
    PARSE_RESULT.DOCUMENT_ID,
    PARSE_RESULT.CHUNK_NUMBER,
    PAGE.VALUE:index::NUMBER AS PAGE_INDEX,
    PAGE.VALUE AS PAGE_OBJECT

FROM TEMP_CHUNK_PARSE AS PARSE_RESULT,

LATERAL FLATTEN(
    INPUT => COALESCE(
        PARSE_RESULT.RAW_PARSE_RESPONSE:value:pages,
        PARSE_RESULT.RAW_PARSE_RESPONSE:pages
    )
) AS PAGE

WHERE PARSE_RESULT.RAW_PARSE_RESPONSE:error IS NULL
   OR IS_NULL_VALUE(PARSE_RESULT.RAW_PARSE_RESPONSE:error);


/* Step 6B:
   Combine all chunk pages into one ordered parse response.
*/

CREATE OR REPLACE TEMP TABLE TEMP_COMBINED_CHUNK_PARSE AS
SELECT
    DOCUMENT_ID,

    OBJECT_CONSTRUCT(
        'value',
        OBJECT_CONSTRUCT(
            'pages',
            ARRAY_AGG(PAGE_OBJECT)      -- Combine all pages from all chunks into one array, preserving order.
                WITHIN GROUP (ORDER BY CHUNK_NUMBER, PAGE_INDEX)
        ),
        'error',
        NULL,
        'metadata',
        OBJECT_CONSTRUCT(
            'pageCount', COUNT(*)
        )
    ) AS RAW_PARSE_RESPONSE

FROM TEMP_CHUNK_PAGES
GROUP BY DOCUMENT_ID;



/* Step 6C:
   Store one combined CHUNKED parse result.
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
SELECT
    COMBINED.DOCUMENT_ID,
    $PARSE_VERSION,
    $PARSE_MODE,

    OBJECT_CONSTRUCT(
        'mode', $PARSE_MODE,
        'page_split', TRUE,
        'chunk_size', $PARSE_CHUNK_SIZE
    ) AS PARSE_CONFIG,

    'CHUNKED' AS PARSE_METHOD,
    NULL AS CHUNK_NUMBER,

    COMBINED.RAW_PARSE_RESPONSE,

    CASE
        WHEN ARRAY_SIZE(
            COMBINED.RAW_PARSE_RESPONSE:value:pages
        ) = DOCUMENT.PAGE_COUNT
            THEN 'SUCCESS'
        ELSE 'FAILED'
    END AS RUN_STATUS,

    CASE
        WHEN ARRAY_SIZE(
            COMBINED.RAW_PARSE_RESPONSE:value:pages
        ) != DOCUMENT.PAGE_COUNT
            THEN 'Combined chunk page count does not match registry page count'
        ELSE NULL
    END AS ERROR_MESSAGE

FROM TEMP_COMBINED_CHUNK_PARSE AS COMBINED

INNER JOIN TEMP_DOCUMENT AS DOCUMENT
    ON COMBINED.DOCUMENT_ID = DOCUMENT.DOCUMENT_ID;


-- Verify that the parse results were stored correctly.
SELECT
    PARSE_RUN_ID,
    DOCUMENT_ID,
    PARSE_METHOD,
    CHUNK_NUMBER,
    RUN_STATUS,
    ERROR_MESSAGE
FROM RAW_PARSE_RESULTS
WHERE DOCUMENT_ID = $DOCUMENT_ID
ORDER BY PARSE_RUN_ID DESC;



-- Verify that the combined chunked parse matches the registry page count.
SELECT
    PARSE.PARSE_RUN_ID,
    PARSE.PARSE_METHOD,
    ARRAY_SIZE(
        COALESCE(
            PARSE.RAW_PARSE_RESPONSE:value:pages,
            PARSE.RAW_PARSE_RESPONSE:pages
        )
    ) AS STORED_PAGE_COUNT,
    DOCUMENT.PAGE_COUNT AS REGISTRY_PAGE_COUNT

FROM RAW_PARSE_RESULTS AS PARSE
INNER JOIN CTL_DOCUMENT_REGISTRY AS DOCUMENT
    ON PARSE.DOCUMENT_ID = DOCUMENT.DOCUMENT_ID

WHERE PARSE.PARSE_RUN_ID = (
    SELECT MAX(PARSE_RUN_ID)
    FROM RAW_PARSE_RESULTS
    WHERE DOCUMENT_ID = $DOCUMENT_ID
      AND PARSE_VERSION = $PARSE_VERSION
      AND PARSE_MODE = $PARSE_MODE
);


/* Step 7:
   Report the latest successful parse result for the current document.
*/

SELECT
    PARSE.PARSE_RUN_ID,
    PARSE.DOCUMENT_ID,
    PARSE.PARSE_METHOD,
    PARSE.RUN_STATUS,
    PARSE.ERROR_MESSAGE,
    PARSE.PARSED_AT

FROM RAW_PARSE_RESULTS AS PARSE

WHERE PARSE.DOCUMENT_ID = $DOCUMENT_ID
  AND PARSE.PARSE_VERSION = $PARSE_VERSION
  AND PARSE.PARSE_MODE = $PARSE_MODE

ORDER BY PARSE.PARSE_RUN_ID DESC
LIMIT 1;


/* Step 8:
   Confirm the latest successful parse available for extraction.
*/

SELECT
    PARSE.PARSE_RUN_ID,
    PARSE.DOCUMENT_ID,
    PARSE.PARSE_VERSION,
    PARSE.PARSE_MODE,
    PARSE.PARSE_METHOD,
    PARSE.PARSE_CONFIG,

    COALESCE(
        PARSE.RAW_PARSE_RESPONSE:metadata:pageCount::NUMBER,
        PARSE.RAW_PARSE_RESPONSE:value:metadata:pageCount::NUMBER
    ) AS PAGE_COUNT,

    PARSE.RUN_STATUS,
    PARSE.ERROR_MESSAGE,
    PARSE.PARSED_AT

FROM RAW_PARSE_RESULTS AS PARSE

WHERE PARSE.DOCUMENT_ID = $DOCUMENT_ID
  AND PARSE.PARSE_VERSION = $PARSE_VERSION
  AND PARSE.PARSE_MODE = $PARSE_MODE
  AND PARSE.RUN_STATUS = 'SUCCESS'

ORDER BY PARSE.PARSE_RUN_ID DESC
LIMIT 1;



-- Set the PARSE_RUN_ID for downstream extraction steps.
SET PARSE_RUN_ID = (
    SELECT MAX(PARSE_RUN_ID)
    FROM RAW_PARSE_RESULTS
    WHERE DOCUMENT_ID = $DOCUMENT_ID
      AND PARSE_VERSION = $PARSE_VERSION
      AND PARSE_MODE = $PARSE_MODE
      AND RUN_STATUS = 'SUCCESS'
);

-- Confirm the parse run selected for downstream steps.
SELECT $PARSE_RUN_ID AS PARSE_RUN_ID;

