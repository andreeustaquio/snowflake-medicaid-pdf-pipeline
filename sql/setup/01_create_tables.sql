/*
Purpose:
    Create the control, raw-result, page batch, standardized tables used by the PDF extraction pipeline

Process:
    1. Create the document registry table.
    2. Create the raw parse result table.
    3. Create the raw extraction result table.
    4. Create the page-level batch table.
    5. Create the standardized fee schedule table based on state-specific schema (e.g., ND, NM, etc.)
    
Objects:
    CTL_DOCUMENT_REGISTRY
    RAW_PARSE_RESULTS
    RAW_EXTRACTION_RESULTS
    PARSE_PAGE_BATCHES
    STANDARDIZED_FEE_SCHEDULE (Create based on state-specific schema, e.g., ND, NM, etc.)
 */

 /*
 Important:
    - Set DATABASE, SCHEMA, and WAREHOUSE before running.
    - This script is intended to be run once to create the necessary tables for the pipeline.
    - If you need to re-run this script, consider dropping the tables first or using CREATE OR REPLACE TABLE statements.

    Additional notes on lineage:
    - DOCUMENT_ID identifies the source document.
    - PARSE_RUN_ID identifies a stored raw parse result.
    - EXTRACTION_RESULT_ID identifies an individual stored AI_EXTRACT result.
    - RAW_EXTRACTION_RESULTS retains DOCUMENT_ID, PARSE_RUN_ID, PAGE_NUMBER, and BATCH_ID to trace extraction results back to their source.
    - STANDARDIZED_FEE_SCHEDULE retains EXTRACTION_RESULT_ID, PAGE_NUMBER, and SOURCE_ROW_INDEX to trace standardized rows back to the raw
      extraction result from which they were produced.
  */

/*
Session prerequisites:
- Set DATABASE, SCHEMA, and WAREHOUSE before running.

Example:
USE DATABASE <DB_NAME>;
USE SCHEMA <SCHEMA_NAME>;
USE WAREHOUSE <WAREHOUSE_NAME>;
*/

/*
    Document metadata.
*/
CREATE TABLE IF NOT EXISTS CTL_DOCUMENT_REGISTRY (
    DOCUMENT_ID NUMBER AUTOINCREMENT,

    DOCUMENT_TYPE VARCHAR NOT NULL,
    STATE_CODE VARCHAR(2),
    COMPLEXITY_LEVEL VARCHAR,
    PAGE_COUNT NUMBER,

    STAGE_NAME VARCHAR NOT NULL,
    RELATIVE_PATH VARCHAR NOT NULL,
    FILE_NAME VARCHAR NOT NULL,

    FILE_SIZE_BYTES NUMBER,
    FILE_LAST_MODIFIED TIMESTAMP_TZ,
    FILE_MD5 VARCHAR,

    PROCESSING_STATUS VARCHAR DEFAULT 'NOT_STARTED',
    NOTES VARCHAR,

    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Inventory and processing status for Medicaid fee schedule and reference documents.';

/*
    Table to store raw parsed AI_PARSE_DOCUMENT results and preserve history.
*/
CREATE TABLE IF NOT EXISTS RAW_PARSE_RESULTS (
    PARSE_RUN_ID NUMBER AUTOINCREMENT,
    DOCUMENT_ID NUMBER NOT NULL,

    PARSE_VERSION VARCHAR DEFAULT 'V1',
    PARSE_MODE VARCHAR,
    PARSE_CONFIG VARIANT,
    
    PARSE_METHOD VARCHAR,   -- FULL or CHUNKED
    CHUNK_NUMBER NUMBER,    -- NULL for full document parse, otherwise the chunk number for a multi-chunk parse.

    RAW_PARSE_RESPONSE VARIANT,

    RUN_STATUS VARCHAR,
    ERROR_MESSAGE VARCHAR,

    PARSED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Append-only history of AI_PARSE_DOCUMENT executions and raw responses.';


/*
    Table to store raw AI_EXTRACT results history, including schema, response, scores, and errors.
*/
CREATE TABLE IF NOT EXISTS RAW_EXTRACTION_RESULTS (
    EXTRACTION_RESULT_ID NUMBER AUTOINCREMENT,
    DOCUMENT_ID NUMBER NOT NULL,

    PARSE_RUN_ID NUMBER,
    EXTRACTION_VERSION VARCHAR DEFAULT 'V1',
    INPUT_TYPE VARCHAR DEFAULT 'FILE',

    PAGE_NUMBER NUMBER,
    BATCH_ID NUMBER,
    EXTRACTION_CONFIDENCE FLOAT,
    ATTEMPT_NUMBER NUMBER DEFAULT 1,
    SCHEMA_VERSION VARCHAR,

    RESPONSE_FORMAT VARIANT,
    EXTRACTION_CONFIG VARIANT,
    SCORES_REQUESTED BOOLEAN DEFAULT FALSE,

    RAW_EXTRACTION_RESPONSE VARIANT,

    RUN_STATUS VARCHAR,
    ERROR_MESSAGE VARCHAR,

    EXTRACTED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Append-only history of AI_EXTRACT executions, configurations, responses, and scores.';


/*
    Table to store the flattened parsed document pages grouped into extraction batches.
*/
CREATE OR REPLACE TRANSIENT TABLE PARSE_PAGE_BATCHES
(
    BATCH_RUN_ID NUMBER AUTOINCREMENT,      -- BATCH_RUN_ID is a unique identifier for each batch of pages processed for extraction. It is used to track the processing status of each batch.

    DOCUMENT_ID NUMBER NOT NULL,
    PARSE_RUN_ID NUMBER NOT NULL,

    PAGE_NUMBER NUMBER NOT NULL,
    PAGE_TEXT VARCHAR,

    BATCH_ID NUMBER NOT NULL,   -- BATCH_ID is used to group pages into batches for extraction. For example, if BATCH_SIZE = 10, then pages 1-10 will have BATCH_ID = 0, pages 11-20 will have BATCH_ID = 1, and so on.
    BATCH_SIZE NUMBER,  -- BATCH_SIZE is the number of pages to process in each batch. It can be adjusted based on document size and warehouse capacity.

    PROCESSING_STATUS VARCHAR DEFAULT 'NOT_STARTED',

    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    UPDATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)

COMMENT = 'Flattened parsed document pages grouped into extraction batches.';


/*
    Table to store standardized Medicaid fee schedule rows transformed from raw extraction results.
*/
CREATE TABLE IF NOT EXISTS STANDARDIZED_FEE_SCHEDULE_ND (
    STANDARDIZED_ROW_ID NUMBER AUTOINCREMENT,

    DOCUMENT_ID NUMBER NOT NULL,
    PARSE_RUN_ID NUMBER,
    EXTRACTION_VERSION VARCHAR,
    EXTRACTION_RESULT_ID NUMBER,

    PAGE_NUMBER NUMBER,
    SOURCE_ROW_INDEX NUMBER,

    STATE_CODE VARCHAR(2),

    PROCEDURE_CODE VARCHAR,
    MODIFIER VARCHAR,
    MEDICAID_FEE NUMBER(12,2),
    
    SCHEMA_VERSION VARCHAR,
    TRANSFORMATION_VERSION VARCHAR DEFAULT 'V1',
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Standardized Medicaid fee schedule ND rows transformed from raw extraction results.';


CREATE TABLE IF NOT EXISTS STANDARDIZED_FEE_SCHEDULE_NM (
    STANDARDIZED_ROW_ID NUMBER AUTOINCREMENT,

    DOCUMENT_ID NUMBER NOT NULL,
    PARSE_RUN_ID NUMBER,
    EXTRACTION_VERSION VARCHAR,
    EXTRACTION_RESULT_ID NUMBER,

    PAGE_NUMBER NUMBER,
    SOURCE_ROW_INDEX NUMBER,

    STATE_CODE VARCHAR(2),

    CPT_CODE VARCHAR,
    TAX VARCHAR,
    RATE NUMBER(12,2),
    PRICING_NOTE VARCHAR,
    VFC VARCHAR,
    MODIFIER VARCHAR,
    RATE_2 NUMBER(12,2),
    PRICE_START_DATE DATE,
    
    SCHEMA_VERSION VARCHAR,
    TRANSFORMATION_VERSION VARCHAR DEFAULT 'V1',
    CREATED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
)
COMMENT = 'Standardized Medicaid fee schedule NM rows transformed from raw extraction results.';
