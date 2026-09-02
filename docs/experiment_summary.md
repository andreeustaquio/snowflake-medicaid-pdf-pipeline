# Experiment summary

This document summarizes the main experiments and design decisions used to develop the Snowflake Medicaid fee schedule extraction pipeline.

The project tested state fee schedule PDFs with different sizes and table structures to understand how Snowflake Cortex `AI_PARSE_DOCUMENT` and `AI_EXTRACT` could support a repeatable extraction workflow. North Dakota (ND), Arkansas (AR), and New Hampshire (NH) were used for progressive experimentation. New Mexico (NM) became the second state supported by the final pipeline.

The final design uses a common processing framework with state-specific extraction, transformation, and validation where document schemas differ.

## Experiment progression

The experiments increased document size and structural complexity while testing whether the same core pipeline approach could be reused.

* **North Dakota (ND)** established the baseline with a 322-page, three-column fee schedule and became the first supported state.
* **Arkansas (AR)** expanded testing to a 638-page, seven-column document and introduced wider-schema and column-alignment challenges.
* **New Hampshire (NH)** tested a 1,071-page, 12-column document and exposed full-document parsing limitations that led to chunked-parsing and page-count experiments.
* **New Mexico (NM)** became the second supported state and demonstrated the final state-specific pipeline and orchestration approach.

## North Dakota: Establish the baseline

ND provided the initial three-column use case: procedure code, modifier, and Medicaid fee. The full 322-page document was successfully parsed in `LAYOUT` mode with page splitting enabled.

ND was used to develop and test:

* representative-page and full-document parsing
* column-array extraction with `AI_EXTRACT`
* page batching
* transformation and field-cleaning logic
* source-to-target row alignment
* lineage and raw-response storage
* rerun-safe registration, parsing, extraction, and loading

The transformation experiments established several rules retained in later work. Procedure codes are stored as strings because they are identifiers. Extracted arrays are aligned by their shared index. Blank and `"None"` values are normalized to `NULL`, and fee values are safely converted with `TRY_TO_DECIMAL`.

ND established the baseline workflow:

`register → parse → review → extract → evaluate → load → validate`

## Arkansas: Test a wider schema

AR increased the document size to 638 pages and expanded the extraction schema from three to seven columns, including four modifier fields, provider program, and Medicaid maximum allowed amount.

The same overall pipeline architecture remained usable, but the wider table exposed new extraction-quality concerns.

AR also exposed cases where values could shift between neighboring procedure-code and modifier columns. More explicit schema descriptions were added to instruct extraction to preserve row alignment and avoid borrowing values from adjacent columns.

This experiment reinforced two decisions:

* use human-reviewed extraction schemas
* validate column and row alignment, not only whether expected fields were returned

## New Hampshire: Test large-document processing

NH increased the experiment to 1,071 pages and approximately 12 expected columns.

The initial full-document `AI_PARSE_DOCUMENT` attempt ran for approximately 45 minutes before returning a context deadline timeout. This showed that a document can meet input requirements while still being impractical to process reliably in one long-running call.

Chunked parsing was tested as an alternative. A 100-page range parsed successfully in approximately 2.5 minutes during initial testing. This led to experiments with:

* configurable page-count thresholds
* full-versus-chunked parsing
* generated page ranges
* chunk-level validation
* representative-page inspection

A Snowflake Python UDF was also explored to determine PDF page count before parsing. The intended use was to select full or chunked processing automatically based on document size.

Chunking and the page-count UDF were not required for the final ND/NM implementation, so they remain archived as possible extensions for larger documents.

NH extraction testing also produced a useful data-quality case: the lowest-confidence page contained non-table content that did not match the expected fee-schedule schema. This reinforced the value of confidence scores as review signals rather than treating successful AI execution as sufficient validation.

## New Mexico: Apply the final pipeline pattern

NM became the second state supported by the final pipeline.

The 339-page document uses an eight-field extraction schema and state-specific extraction, evaluation, transformation, and validation scripts. It shares the common configuration, registration, parsing, lineage, and orchestration framework used by ND.

This led to the final extensibility pattern:

`common pipeline framework + state-specific data logic`

The final NM test processed all 339 pages successfully with no failed extraction pages and loaded 11,134 standardized rows.

NM also became the main test case for the lightweight Python orchestration layer. The workflow is divided into:

`prepare → human review → complete`

`prepare` registers and parses the document, tests representative-page extraction, and stops for review. `complete` restores the stored document and parse state before running full extraction, evaluation, loading, and final validation.

## Key design decisions

### Parse before full extraction

The final workflow stores parsed page content before full extraction. This creates a reusable intermediate result that can be inspected and passed to `AI_EXTRACT` without reparsing the PDF.

Direct extraction was also explored and remains archived as an alternative approach.

### Review representative pages first

Representative-page extraction is tested before full extraction. The final orchestrator intentionally preserves this human-review checkpoint.

### Use state-specific schemas

State documents vary too much for complexity level alone to determine the extraction schema. The final approach uses explicit, human-reviewed schemas for each supported state while sharing the surrounding pipeline framework.

### Validate data quality between stages

Validation includes parse status, representative extraction, confidence scores, array alignment, row reconciliation, duplicate checks, field quality, and selected value distributions.

A review flag indicates that output should be inspected; it does not necessarily mean the pipeline failed.

### Preserve lineage and raw responses

Document, parse, extraction, page, and source-row identifiers are retained so standardized records can be traced to earlier processing stages. Raw AI responses are also retained for troubleshooting and comparison.

### Make expensive operations rerun-safe

The pipeline checks for existing document versions, successful parses, successful page extractions, and previously loaded records before repeating work.

### Keep optional approaches archived

Several useful approaches were tested without becoming requirements of the final pipeline:

* page batching
* direct extraction
* chunked parsing
* Python page-count UDF

Keeping these experiments separate allows future development without making the supported pipeline unnecessarily complex.

## Limitations

The final pipeline demonstrates a reusable processing framework, but it is not a universal Medicaid fee schedule extraction solution.

* **State-specific schemas are still required.** Medicaid fee schedules vary in layout, terminology, and column structure. A new state may require its own extraction, transformation, and validation logic.
* **Representative-page review is manual.** The pipeline intentionally uses human review before full extraction rather than automatically determining whether a document is safe to process.
* **Large-document handling is not part of the supported pipeline.** Chunked parsing was tested successfully as an alternative when the NH full-document parse timed out, but it remains experimental. During the experiment, chunking the full document before parsing significantly reduced the parsing runtime.
* **Document structure can vary within a PDF.** Non-table pages may not match the extraction schema and can produce lower-confidence or incomplete results.
* **Confidence scores are review signals, not guarantees of correctness.** Extraction quality still requires checks for alignment, row counts, field values, and source-document consistency.
* **Adding a state is not fully automated.** The current design favors explicit, human-reviewed schemas over automatically generated production schemas.

## Future development opportunities

The archived experiments provide several paths for extending the pipeline.

* **Choose the parsing strategy before processing.** Use a pre-parse page-count mechanism to classify larger documents and select full-document or chunked parsing automatically.
* **Promote chunked parsing into the supported pipeline.** Generate page ranges, parse each chunk independently, validate chunk completeness, and combine the stored pages for downstream extraction.
* **Improve handling of non-table pages.** Add logic to identify pages that do not match the expected fee-schedule structure before extraction or route them for review.
* **Expand state support.** Add state-specific schemas and transformations while continuing to reuse the common registration, parsing, lineage, orchestration, and validation framework.
* **Extend retry and recovery behavior.** Page- or chunk-level processing could support targeted retries without repeating successful work.

## Archived experiments

Experimental SQL is retained under `sql/experiments/` and organized by technique:

* `parse_baselines/` — representative-page and full-document parsing
* `direct_extraction/` — alternative extraction approaches
* `batching/` — earlier page-batch processing
* `transformation/` — array alignment and cleaning development
* `chunked_parsing/` — large-document and page-range parsing
* `page_count_udf/` — experimental PDF page-count helper

These scripts are not part of the active orchestrated pipeline. They are retained as examples of the approaches tested and as starting points for future development.

## Outcome

The experiments evolved from single-page document parsing into a rerun-safe, state-aware extraction pipeline with validation, lineage, and lightweight orchestration.

The main lesson was that Snowflake's AI functions provide flexibility for working with differing document structures, but useful structured data still depends on explicit schemas, data-quality checks, and human review.

The final workflow reflects that balance:

`understand → test → parse → review → extract → validate → load → reconcile`
