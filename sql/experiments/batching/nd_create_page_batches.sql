/*
Purpose:
Create extraction batches from a successful parsed document
and store the page-level batches in PARSE_PAGE_BATCHES.

Process:
1. Confirm the selected parse run exists and succeeded.
2. Check whether pages from this parse run were already batched.
3. Insert any missing parsed pages into PARSE_PAGE_BATCHES.
4. Verify batch counts.
*/

/*
Session prerequisites:
Run 00_config.sql to set DATABASE, SCHEMA, and WAREHOUSE, parameters, and stage name before running this script.
*/


/* Step 1:
Confirm the selected parse run exists and succeeded.
*/
SELECT
    PARSE_RUN_ID,
    DOCUMENT_ID,
    PARSE_MODE,
    PARSED_AT,
    RUN_STATUS
FROM RAW_PARSE_RESULTS
WHERE DOCUMENT_ID = $DOCUMENT_ID
  AND PARSE_RUN_ID = $PARSE_RUN_ID
  AND RUN_STATUS = $RUN_STATUS;


/* Step 2:
Check whether this parse run has already been batched.
*/
SELECT
    COUNT(*) AS EXISTING_BATCHED_PAGES
FROM PARSE_PAGE_BATCHES
WHERE DOCUMENT_ID = $DOCUMENT_ID
  AND PARSE_RUN_ID = $PARSE_RUN_ID;


/* Step 3:
Insert parsed pages that have not already been batched.
*/
INSERT INTO PARSE_PAGE_BATCHES
(
    DOCUMENT_ID,
    PARSE_RUN_ID,
    PAGE_NUMBER,
    PAGE_TEXT,
    BATCH_ID,
    BATCH_SIZE
)

SELECT
    r.DOCUMENT_ID,
    r.PARSE_RUN_ID,
    f.index AS PAGE_NUMBER,
    f.value:content::VARCHAR AS PAGE_TEXT,
    FLOOR(f.index / $BATCH_SIZE) AS BATCH_ID,
    $BATCH_SIZE AS BATCH_SIZE

FROM RAW_PARSE_RESULTS AS r,
LATERAL FLATTEN(
    input => COALESCE(
        r.RAW_PARSE_RESPONSE:pages,
        r.RAW_PARSE_RESPONSE:value:pages
    )
) AS f

WHERE r.DOCUMENT_ID = $DOCUMENT_ID
  AND r.PARSE_RUN_ID = $PARSE_RUN_ID
  AND r.RUN_STATUS = $RUN_STATUS

  AND NOT EXISTS (
      SELECT 1
      FROM PARSE_PAGE_BATCHES AS b
      WHERE b.DOCUMENT_ID = r.DOCUMENT_ID
        AND b.PARSE_RUN_ID = r.PARSE_RUN_ID
        AND b.PAGE_NUMBER = f.index
        AND b.BATCH_SIZE = $BATCH_SIZE
  );
  

/* Step 4:
Verify the stored batches.
*/
SELECT
    BATCH_ID,
    COUNT(*) AS PAGE_COUNT
FROM PARSE_PAGE_BATCHES
WHERE DOCUMENT_ID = $DOCUMENT_ID
  AND PARSE_RUN_ID = $PARSE_RUN_ID
GROUP BY BATCH_ID
ORDER BY BATCH_ID;


SELECT
    COUNT(*) AS EXISTING_BATCHED_PAGES
FROM PARSE_PAGE_BATCHES
WHERE DOCUMENT_ID = $DOCUMENT_ID
  AND PARSE_RUN_ID = $PARSE_RUN_ID
  AND BATCH_SIZE = $BATCH_SIZE;

