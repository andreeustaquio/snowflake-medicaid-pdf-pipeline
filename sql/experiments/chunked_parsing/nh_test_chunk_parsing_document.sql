/*
Purpose:
Parse a large document in smaller page ranges to avoid
AI_PARSE_DOCUMENT timeout, then combine the chunks into the
same TEMP_FULL_PARSE structure used by the normal parse workflow.
*/

SELECT
    START_PAGE,
    END_PAGE,
    ARRAY_SIZE(
        RAW_PARSE_RESPONSE:value:pages
    ) AS PARSED_PAGES,
    RAW_PARSE_RESPONSE:error AS PARSE_ERROR
FROM TEMP_CHUNK_PARSE
ORDER BY START_PAGE;

/* 
Step 1: Create temporary chunk storage.
 */

CREATE TEMP TABLE IF NOT EXISTS TEMP_CHUNK_PARSE (
    DOCUMENT_ID VARCHAR,
    START_PAGE NUMBER,
    END_PAGE NUMBER,
    RAW_PARSE_RESPONSE VARIANT
);


/* 
Step 2: Set the current chunk.
 */

SET START_PAGE = 0;
SET END_PAGE = 100;


/* 
Step 3: Parse the chunk only if it has not already been run.
*/

INSERT INTO TEMP_CHUNK_PARSE (
    DOCUMENT_ID,
    START_PAGE,
    END_PAGE,
    RAW_PARSE_RESPONSE
)

SELECT
    DOCUMENT.DOCUMENT_ID,
    $START_PAGE,
    $END_PAGE,

    AI_PARSE_DOCUMENT(
        TO_FILE(
            '@MEDICAID_FEE_SCHEDULE_PDFS',
            DOCUMENT.RELATIVE_PATH
        ),
        OBJECT_CONSTRUCT(
            'mode', $PARSE_MODE,
            'page_filter',
            ARRAY_CONSTRUCT(
                OBJECT_CONSTRUCT(
                    'start', $START_PAGE,
                    'end', $END_PAGE
                )
            )
        ),
        TRUE
    )

FROM TEMP_DOCUMENT_TO_PARSE AS DOCUMENT

WHERE NOT EXISTS (
    SELECT 1
    FROM TEMP_CHUNK_PARSE AS CHUNK
    WHERE CHUNK.DOCUMENT_ID = DOCUMENT.DOCUMENT_ID
      AND CHUNK.START_PAGE = $START_PAGE
      AND CHUNK.END_PAGE = $END_PAGE
);


/* 
Step 4: Validate chunks parsed so far.
*/

SELECT
    START_PAGE,
    END_PAGE,
    END_PAGE - START_PAGE AS EXPECTED_PAGES,

    ARRAY_SIZE(
        RAW_PARSE_RESPONSE:value:pages
    ) AS PARSED_PAGES,

    RAW_PARSE_RESPONSE:error AS PARSE_ERROR

FROM TEMP_CHUNK_PARSE
ORDER BY START_PAGE;


/* 
Step 5: After ALL chunks are complete, flatten all pages.
 */

CREATE OR REPLACE TEMP TABLE TEMP_ALL_PARSED_PAGES AS

SELECT
    $DOCUMENT_ID AS DOCUMENT_ID,
    PAGE.value:index::NUMBER AS PAGE_NUMBER,
    PAGE.value:content::VARCHAR AS PAGE_TEXT,
    PAGE.value AS RAW_PAGE

FROM TEMP_CHUNK_PARSE AS CHUNK,
LATERAL FLATTEN(
    INPUT => CHUNK.RAW_PARSE_RESPONSE:value:pages
) AS PAGE;



/* 
Step 6: Validate whole-document coverage.
 */

SELECT
    COUNT(*) AS TOTAL_PAGES,
    COUNT(DISTINCT PAGE_NUMBER) AS DISTINCT_PAGES,
    MIN(PAGE_NUMBER) AS FIRST_PAGE,
    MAX(PAGE_NUMBER) AS LAST_PAGE

FROM TEMP_ALL_PARSED_PAGES;


/* 
Step 7: Rebuild the normal TEMP_FULL_PARSE structure.
 */

CREATE OR REPLACE TEMP TABLE TEMP_FULL_PARSE AS

SELECT
    DOCUMENT_ID,

    OBJECT_CONSTRUCT(
        'error', NULL,

        'metadata',
        OBJECT_CONSTRUCT(
            'pageCount', COUNT(*)
        ),

        'value',
        OBJECT_CONSTRUCT(
            'pages',
            ARRAY_AGG(RAW_PAGE)
                WITHIN GROUP (
                    ORDER BY PAGE_NUMBER
                )
        )
    ) AS RAW_PARSE_RESPONSE

FROM TEMP_ALL_PARSED_PAGES

GROUP BY DOCUMENT_ID;


/* 
Step 8: Final validation before RAW_PARSE_RESULTS insert.
 */

SELECT
    DOCUMENT_ID,

    RAW_PARSE_RESPONSE:error AS PARSE_ERROR,

    RAW_PARSE_RESPONSE:metadata:pageCount::NUMBER
        AS EXPECTED_PAGE_COUNT,

    ARRAY_SIZE(
        RAW_PARSE_RESPONSE:value:pages
    ) AS PARSED_PAGE_COUNT

FROM TEMP_FULL_PARSE;


-- /* 
-- Step 9:
-- Store the combined chunked parse in RAW_PARSE_RESULTS.
--  */

-- INSERT INTO RAW_PARSE_RESULTS (
--     DOCUMENT_ID,
--     PARSE_VERSION,
--     PARSE_MODE,
--     PARSE_CONFIG,
--     RAW_PARSE_RESPONSE,
--     RUN_STATUS,
--     ERROR_MESSAGE
-- )

-- WITH NORMALIZED_PARSE AS (

--     SELECT
--         PARSE_RESULT.DOCUMENT_ID,
--         PARSE_RESULT.RAW_PARSE_RESPONSE,

--         PARSE_RESULT.RAW_PARSE_RESPONSE:value:pages
--             AS PARSED_PAGES,

--         PARSE_RESULT.RAW_PARSE_RESPONSE:metadata
--             AS PARSE_METADATA,

--         PARSE_RESULT.RAW_PARSE_RESPONSE:error
--             AS PARSE_ERROR

--     FROM TEMP_FULL_PARSE AS PARSE_RESULT
-- )

-- SELECT
--     DOCUMENT_ID,

--     $PARSE_VERSION AS PARSE_VERSION,

--     $PARSE_MODE AS PARSE_MODE,

--     /* Record that this document was parsed in chunks. */
--     OBJECT_CONSTRUCT(
--         'mode', $PARSE_MODE,
--         'page_split', TRUE,
--         'parse_method', 'CHUNKED',
--         'chunk_size', 100
--     ) AS PARSE_CONFIG,

--     RAW_PARSE_RESPONSE,

--     /* Determine whether the combined parse succeeded. */
--     CASE
--         WHEN PARSE_ERROR IS NOT NULL
--              AND NOT IS_NULL_VALUE(PARSE_ERROR)
--             THEN 'FAILED'

--         WHEN COALESCE(
--             ARRAY_SIZE(PARSED_PAGES),
--             0
--         ) = 0
--             THEN 'FAILED'

--         WHEN PARSE_METADATA:pageCount::NUMBER IS NULL
--             THEN 'FAILED'

--         WHEN PARSE_METADATA:pageCount::NUMBER
--              != ARRAY_SIZE(PARSED_PAGES)
--             THEN 'FAILED'

--         ELSE 'SUCCESS'
--     END AS RUN_STATUS,

--     /* Store a useful error message if validation failed. */
--     CASE
--         WHEN PARSE_ERROR IS NOT NULL
--              AND NOT IS_NULL_VALUE(PARSE_ERROR)
--             THEN PARSE_ERROR::VARCHAR

--         WHEN COALESCE(
--             ARRAY_SIZE(PARSED_PAGES),
--             0
--         ) = 0
--             THEN 'Parser returned no pages'

--         WHEN PARSE_METADATA:pageCount::NUMBER IS NULL
--             THEN 'Parser response is missing metadata.pageCount'

--         WHEN PARSE_METADATA:pageCount::NUMBER
--              != ARRAY_SIZE(PARSED_PAGES)
--             THEN 'Metadata page count does not match stored page count'

--         ELSE NULL
--     END AS ERROR_MESSAGE

-- FROM NORMALIZED_PARSE;


-- -- Confirm what was stored in RAW_PARSE_RESULTS.
-- SELECT
--     PARSE_RUN_ID,
--     DOCUMENT_ID,
--     PARSE_VERSION,
--     PARSE_MODE,
--     PARSE_CONFIG,
--     RUN_STATUS,
--     ERROR_MESSAGE,
--     PARSED_AT

-- FROM RAW_PARSE_RESULTS

-- WHERE DOCUMENT_ID = $DOCUMENT_ID
--   AND PARSE_VERSION = $PARSE_VERSION

-- ORDER BY PARSE_RUN_ID DESC
-- LIMIT 1;

-- -- Set downstram PARSE_RUN_ID for fee schedule extraction.
-- SET PARSE_RUN_ID = (
--     SELECT MAX(PARSE_RUN_ID)
--     FROM RAW_PARSE_RESULTS
--     WHERE DOCUMENT_ID = $DOCUMENT_ID
--       AND PARSE_VERSION = $PARSE_VERSION
--       AND PARSE_MODE = $PARSE_MODE
--       AND RUN_STATUS = 'SUCCESS'
-- );

-- SELECT $PARSE_RUN_ID AS PARSE_RUN_ID;
