/*
Purpose:
    Extract structured fee schedule fields from the first parsed page of the ND Medicaid fee schedule PDF.

Process:
    1. Parse page 0 using AI_PARSE_DOCUMENT in LAYOUT mode.
    2. Pass the parsed page content to AI_EXTRACT to extract the fee schedule table.
    3. Using column-array approach. Extract code, modifier, and Medicaid fee values from the parsed page content.
    4. Return the extracted data with confidence scores.

Objects:
    Source stage: MEDICAID_FEE_SCHEDULE_PDFS
    Test file: ND_FeeSchedule.pdf
*/

/*
Session prerequisites:
- Set DATABASE, SCHEMA, and WAREHOUSE before running.

Example:
USE DATABASE <DB_NAME>;
USE SCHEMA <SCHEMA_NAME>;
USE WAREHOUSE <WAREHOUSE_NAME>;
*/

-- Step 1: Parse the first page of the ND fee schedule.

WITH PARSED_PAGE AS (

    SELECT 
        PARSED_DOCUMENT

    FROM (
        SELECT AI_PARSE_DOCUMENT(
            TO_FILE(
                '@MEDICAID_FEE_SCHEDULE_PDFS',
                'ND_FeeSchedule.pdf'
            ),
            {
                'mode': 'LAYOUT',
                'page_filter': [
                    {
                        'start': 0,
                        'end': 1
                    }
                ]
            },
            TRUE
        ) AS PARSED_DOCUMENT
    )

)

SELECT

AI_EXTRACT(

    text => PARSED_DOCUMENT:value:pages[0]:content::VARCHAR,
    responseFormat => {
        'schema': {
            'type':'object',
    
            'properties': {
    
                'fee_schedule': {
                    'type':'object',
    
                    'description':
                    'ND Medicaid fee schedule table',
    
                    'properties': {
    
                        'code': {
                            'type':'array',
                            'description':'Procedure codes',
                            'items': {
                                'type':'string'
                            }
                        },
    
                        'modifier': {
                            'type':'array',
                            'description':'Procedure modifiers',
                            'items': {
                                'type':'string'
                            }
                        },
    
                        'medicaid_fee': {
                            'type':'array',
                            'description':'Medicaid fee amounts',
                            'items': {
                                'type':'string'
                            }
                        }
                    }
                }
            }
        }
    },

    scores => TRUE 

) AS EXTRACTED_FEE_SCHEDULE

FROM PARSED_PAGE;
