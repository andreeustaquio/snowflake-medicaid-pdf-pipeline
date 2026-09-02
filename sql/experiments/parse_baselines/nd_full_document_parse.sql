/*
Purpose:
    Preserve the original ND full-document parsing experiment used
    before the parse result was stored permanently.

Important:

    This script is intended for testing and validation purposes only.

    This script calls AI_PARSE_DOCUMENT and incurs parsing cost.
    Do not rerun for the current ND PDF because a successful result
    already exists in RAW_PARSE_RESULTS.
    
*/

/*
Session prerequisites:
- Set DATABASE, SCHEMA, and WAREHOUSE before running.

Example:
USE DATABASE <DB_NAME>;
USE SCHEMA <SCHEMA_NAME>;
USE WAREHOUSE <WAREHOUSE_NAME>;
*/

-- Parse the entire ND Medicaid fee schedule PDF.
SELECT AI_PARSE_DOCUMENT(
    TO_FILE(
        '@MEDICAID_FEE_SCHEDULE_PDFS',
        'ND_FeeSchedule.pdf'
    ),
    {
        'mode': 'LAYOUT',
        'page_split': TRUE
    },
    TRUE
) AS PARSED_DOCUMENT;
