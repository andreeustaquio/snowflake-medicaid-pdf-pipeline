/*
Purpose:
    Central session configuration for the fee schedule pipeline.
    Run this first to set the document, version, and threshold
    variables that every downstream pipeline script reads.

Example:
SET STATE_CODE = 'AR';
SET FILE_NAME = 'AR_FeeSchedule.pdf';
SET STANDARDIZED_TABLE_NAME = 'STANDARDIZED_FEE_SCHEDULE_AR';
*/

-- Set the database, schema, and warehouse to use for this session.
USE DATABASE <DB_NAME>;
USE SCHEMA <SCHEMA_NAME>;
USE WAREHOUSE <WAREHOUSE_NAME>;


-- Document inputs
SET STATE_CODE = 'NM';
SET FILE_NAME = 'NM_FeeSchedule.pdf';
SET STAGE_NAME = 'MEDICAID_FEE_SCHEDULE_PDFS';
SET DOCUMENT_TYPE = 'MEDICAID_FFS_FEE_SCHEDULE';
SET COMPLEXITY_LEVEL = 'SIMPLE';


-- Standardized table target for this document/profile.
SET STANDARDIZED_TABLE_NAME = 'STANDARDIZED_FEE_SCHEDULE_NM';


-- Pipeline versions
SET SCHEMA_VERSION = 'V1';  -- Change when parse/logic schema changes.
SET EXTRACTION_VERSION = 'V2';  --  Change when new response format/schema/extraction logic is implemented.
SET TRANSFORMATION_VERSION = 'V1';  -- Change when new transformation logic is implemented.


-- Primary extraction settings
SET SCORES_REQUESTED = TRUE;
SET CONFIDENCE_THRESHOLD = 0.97;  -- Minimum confidence for extracted values to be considered valid.
SET RUN_STATUS = 'SUCCESS';


-- Parsing settings
SET PARSE_VERSION = 'V1';   -- Change when new parsing logic is implemented.
SET PARSE_MODE = 'LAYOUT';
