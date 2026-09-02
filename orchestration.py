import logging
import os
import sys
import time
from pathlib import Path

import snowflake.connector


# Environment configuration
SNOWFLAKE_USER = os.environ["SNOWFLAKE_USER"]
SNOWFLAKE_ACCOUNT = os.environ["SNOWFLAKE_ACCOUNT"]
SNOWFLAKE_DATABASE = os.environ["SNOWFLAKE_DATABASE"]
SNOWFLAKE_SCHEMA = os.environ["SNOWFLAKE_SCHEMA"]
SNOWFLAKE_WAREHOUSE = os.environ["SNOWFLAKE_WAREHOUSE"]


# Pipeline SQL file paths for each state
STATE_PIPELINES = {
    "ND": {
        "test": "sql/pipeline/03_test_extraction_pages.sql",
        "extract": "sql/pipeline/04_extract_and_store_results.sql",
        "evaluate": "sql/pipeline/05_evaluate_extraction.sql",
        "load": "sql/pipeline/06_load_standardized_fee_schedule.sql",
        "validate": "sql/pipeline/07_validate_standardized_load.sql",
    },
    "NM": {
        "test": "sql/pipeline/03a_NM_test_extraction_pages.sql",
        "extract": "sql/pipeline/04a_NM_extract_and_store_results.sql",
        "evaluate": "sql/pipeline/05a_NM_evaluate_extraction.sql",
        "load": "sql/pipeline/06a_NM_load_standardized_fee_schedule.sql",
        "validate": "sql/pipeline/07a_NM_validate_standardized_load.sql",
    },
}


# Log directory
LOG_DIR = Path("logs")
LOG_DIR.mkdir(exist_ok=True)


# Logging configuration
logger = logging.getLogger(__name__)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(message)s",
)

logging.getLogger("snowflake.connector").setLevel(logging.WARNING)

file_handler = logging.FileHandler(
    LOG_DIR / "pipeline.log",
    encoding="utf-8",
)

file_handler.setLevel(logging.INFO)

file_handler.setFormatter(
    logging.Formatter(
        "%(asctime)s | %(levelname)s | %(message)s"
    )
)

logger.addHandler(file_handler)


def connect_to_snowflake():
    """Connect to Snowflake using external browser authentication."""
    connection = snowflake.connector.connect(
        user=SNOWFLAKE_USER,
        account=SNOWFLAKE_ACCOUNT,
        authenticator="externalbrowser",
    )

    return connection


def run_sql_file(connection, file_path, replacements=None):
    """Execute a SQL file and return all result sets."""

    sql_path = Path(file_path)

    sql_text = sql_path.read_text(encoding="utf-8")

    if replacements:
        for key, value in replacements.items():
            sql_text = sql_text.replace(key, value)

    results = []

    try:
        for cursor_result in connection.execute_string(sql_text):
            if cursor_result.description:
                results.append(cursor_result.fetchall())

    except Exception as error:
        logger.error("Error while executing: %s", file_path)
        logger.error(error)
        raise

    return results


def run_stage(connection, stage_name, file_path):
    """Run one SQL pipeline stage and log its results and runtime."""

    logger.info("=" * 60)
    logger.info("Starting: %s", stage_name)
    logger.info("SQL file: %s", file_path)
    logger.info("=" * 60)

    # Measure execution time to output in logs
    start_time = time.time()

    try:
        results = run_sql_file(
            connection,
            file_path,
        )

        print_results(results)

        elapsed_time = time.time() - start_time

        logger.info(
            "Completed: %s (%.1f seconds)",
            stage_name,
            elapsed_time,
        )

    except Exception:
        elapsed_time = time.time() - start_time

        logger.exception(
            "Failed: %s after %.1f seconds",
            stage_name,
            elapsed_time,
        )

        raise



MAX_ROWS_TO_PRINT = 5


def print_results(results):
    """Log useful result sets from SQL execution, filtering out noise and large values.
    
    Skips:
    - Empty result sets
    - Snowflake execution/DDL success messages
    - JSON-like single-column results (typically internal structures)
    - Results containing values > 500 chars (typically large text/JSON)
    - Result sets with > 5 rows (logs summary instead)
    """
    for rows in results:

        if not rows:
            continue

        # Skip Snowflake execution messages
        if len(rows) == 1 and len(rows[0]) == 1:
            value = str(rows[0][0])

            if (
                "successfully created" in value
                or "Statement executed successfully" in value
            ):
                continue

        # Skip JSON-like single-column result sets
        if all(len(row) == 1 for row in rows):
            values = [
                str(row[0]).strip()
                for row in rows
                if row[0] is not None
            ]

            if values and all(
                value.startswith("[") or value.startswith("{")
                for value in values
            ):
                continue

        # Skip large page text and raw responses
        has_large_value = any(
            len(str(value)) > 500
            for row in rows
            for value in row
            if value is not None
        )

        if has_large_value:
            continue

        # Summarize large detail result sets
        if len(rows) > MAX_ROWS_TO_PRINT:
            logger.info(
                "  Detail result omitted (%s rows).",
                len(rows),
            )
            continue

        for row in rows:
            logger.info("  %s", row)



def get_state_code(connection):
    """Retrieve the current STATE_CODE Snowflake session variable."""
    cursor = connection.cursor()

    try:
        cursor.execute("SELECT $STATE_CODE;")

        result = cursor.fetchone()

        return result[0]

    finally:
        cursor.close()



def log_config_state(connection):
    """Log the current pipeline configuration session variables."""
    cursor = connection.cursor()

    try:
        cursor.execute(
            """
            SELECT
                $STATE_CODE,
                $FILE_NAME,
                $PARSE_VERSION,
                $PARSE_MODE;
            """
        )

        result = cursor.fetchone()

        logger.info("STATE_CODE: %s", result[0])
        logger.info("FILE_NAME: %s", result[1])
        logger.info("PARSE_VERSION: %s", result[2])
        logger.info("PARSE_MODE: %s", result[3])

    finally:
        cursor.close()


def log_document_id(connection):
    """Log the current DOCUMENT_ID session variable."""
    cursor = connection.cursor()

    try:
        cursor.execute("SELECT $DOCUMENT_ID;")
        document_id = cursor.fetchone()[0]
        logger.info("DOCUMENT_ID: %s", document_id)

    finally:
        cursor.close()


def log_parse_run_id(connection):
    """Log the current PARSE_RUN_ID session variable."""
    cursor = connection.cursor()

    try:
        cursor.execute("SELECT $PARSE_RUN_ID;")
        parse_run_id = cursor.fetchone()[0]
        logger.info("PARSE_RUN_ID: %s", parse_run_id)

    finally:
        cursor.close()



def run_config(connection):
    """Execute 00_config.sql with environment-specific replacements.
    
    This initializes the Snowflake session with database, schema, and warehouse context.
    Called at the start of each phase since each phase may use a new connection.
    """
    run_sql_file(
        connection,
        "sql/pipeline/00_config.sql",
        replacements={
            "<DB_NAME>": SNOWFLAKE_DATABASE,
            "<SCHEMA_NAME>": SNOWFLAKE_SCHEMA,
            "<WAREHOUSE_NAME>": SNOWFLAKE_WAREHOUSE,
        },
    )
    logger.info("00_config.sql executed successfully.")


def main():
    """Entry point: parse command and run the appropriate pipeline phase."""
    if len(sys.argv) < 2:
        logger.error(
            "Usage: uv run orchestration.py [setup|prepare|complete]"
        )
        sys.exit(2)

    command = sys.argv[1]

    if command not in ["setup", "prepare", "complete"]:
        logger.error("Unknown command: %s", command)
        logger.error(
            "Use setup, prepare, or complete as the command."
        )
        sys.exit(2)

    connection = None

    try:
        connection = connect_to_snowflake()

        logger.info("Connected to Snowflake successfully.")

        if command == "setup":
            run_setup_phase(connection)

        elif command == "prepare":
            run_prepare_phase(connection)

        elif command == "complete":
            run_complete_phase(connection)

    except Exception:
        logger.exception(
            "Pipeline command '%s' failed. Check the logs for details.", 
            command,
        )
        sys.exit(1)

    finally:
        if connection is not None:
            connection.close()
            logger.info("Snowflake connection closed.")



def restore_pipeline_state(connection):
    """Restore DOCUMENT_ID and PARSE_RUN_ID from the database for the current state.
    
    Used by run_complete_phase() to recover pipeline state after connecting in a new session.
    Sets the Snowflake session variables and returns their values for logging.
    """
    cursor = connection.cursor()

    try:
        cursor.execute(
            """
            SET DOCUMENT_ID = (
                SELECT MAX(DOCUMENT_ID)
                FROM CTL_DOCUMENT_REGISTRY
                WHERE STATE_CODE = $STATE_CODE
                  AND FILE_NAME = $FILE_NAME
            );
            """
        )

        cursor.execute(
            """
            SET PARSE_RUN_ID = (
                SELECT MAX(PARSE_RUN_ID)
                FROM RAW_PARSE_RESULTS
                WHERE DOCUMENT_ID = $DOCUMENT_ID
                  AND PARSE_VERSION = $PARSE_VERSION
                  AND PARSE_MODE = $PARSE_MODE
                  AND RUN_STATUS = 'SUCCESS'
            );
            """
        )

        # Retrieve the restored values for logging
        document_id = cursor.execute(
            "SELECT $DOCUMENT_ID"
        ).fetchone()[0]

        parse_run_id = cursor.execute(
            "SELECT $PARSE_RUN_ID"
        ).fetchone()[0]

        if document_id is None:
            raise RuntimeError(
                "No registered document found for the current state and file."
            )

        if parse_run_id is None:
            raise RuntimeError(
                "No successful parse found for the current document."
            )

        return document_id, parse_run_id

    finally:
        cursor.close()




def run_setup_phase(connection):
    """Run one-time setup: initialize config and create tables."""

    logger.info("Starting setup phase...")

    run_config(connection)

    run_stage(
        connection,
        "Create tables",
        "sql/setup/01_create_tables.sql",
    )

    logger.info("Setup phase completed successfully.")



def run_prepare_phase(connection):
    """Prepare phase: register document, parse, test representative pages.
    
    This phase:
    1. Configures the Snowflake session
    2. Registers the document in the catalog
    3. Parses the document using AI_PARSE_DOCUMENT
    4. Tests extraction on representative pages
    
    Intentionally stops here to allow human review of representative-page
    extraction results before proceeding to full extraction (run_complete_phase).
    """
    logger.info("Starting prepare phase...")

    run_config(connection)

    log_config_state(connection)

    state_code = get_state_code(connection)
    pipeline = STATE_PIPELINES[state_code]

    run_stage(
        connection,
        "Register document",
        "sql/pipeline/01_register_document.sql",
    )

    log_document_id(connection)

    run_stage(
        connection,
        "Parse and store document",
        "sql/pipeline/02_parse_and_store.sql"
    )

    log_parse_run_id(connection)

    run_stage(
        connection,
        f"Test extraction for state {state_code}",
        pipeline["test"],
    )

    logger.warning("Review the representative page extraction results before continuing to full extraction.")

    logger.info("Prepare phase completed successfully.")
        



def run_complete_phase(connection):
    """Complete phase: full extraction, evaluation, load, and validation.
    
    This phase:
    1. Configures the Snowflake session
    2. Restores DOCUMENT_ID and PARSE_RUN_ID from the prepare phase
    3. Runs full extraction on all document pages
    4. Evaluates extraction quality
    5. Loads results into the standardized table
    6. Validates the standardized load
    
    This phase must be run after run_prepare_phase() on the same document.
    """
    logger.info("Starting complete phase...")

    run_config(connection)

    state_code = get_state_code(connection)
    pipeline = STATE_PIPELINES[state_code]

    document_id, parse_run_id = restore_pipeline_state(connection)

    logger.info("RESTORED DOCUMENT_ID: %s", document_id)
    logger.info("RESTORED PARSE_RUN_ID: %s", parse_run_id)

    # Full Extraction
    run_stage(
        connection,
        f"Full extraction for state {state_code}",
        pipeline["extract"],
    )

    # Evaluate extraction results
    run_stage(
        connection,
        f"Extraction evaluation for state {state_code}",
        pipeline["evaluate"],
    )

    # Load standardized data
    run_stage(
        connection,
        f"Standardized load for state {state_code}",
        pipeline["load"],
    )

    # Validate standardized load
    run_stage(
        connection,
        f"Standardized load validation for state {state_code}",
        pipeline["validate"],
    )

    logger.info("=" * 60)
    logger.info("PIPELINE COMPLETE")
    logger.info("State: %s", state_code)
    logger.info("Document ID: %s", document_id)
    logger.info("Parse Run ID: %s", parse_run_id)
    logger.info("Status: SUCCESS")
    logger.info("=" * 60)



if __name__ == "__main__":
    main()
