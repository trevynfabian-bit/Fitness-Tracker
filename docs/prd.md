Personal Longitudinal Health Platform — Product Requirements Document
=====================================================================

**Status:** Authoritative Product Requirements**Version:** 1.0**Product status:** Pre-production / phased implementation

1\. Product Overview
====================

1.1 Product definition
----------------------

The Personal Longitudinal Health Platform is a personal health and performance intelligence platform designed to build a durable, longitudinal historical record from fragmented health and performance data.

The product is **not primarily a dashboard**.

Its primary purpose is to create a trustworthy historical data foundation that allows a user to:

*   import data from multiple sources over time;
    
*   preserve source provenance;
    
*   normalize incompatible formats into a canonical model;
    
*   maintain historical continuity across years;
    
*   correct data without destroying reproducibility;
    
*   analyze long-term trends;
    
*   understand changes in health and performance.
    

The platform treats CSV and XLSX as the universal ingestion surface.

The core product principle is:

> Data sources may change. The historical record must survive them.

2\. Problem Statement
=====================

Personal health and performance data is fragmented across:

*   workout applications;
    
*   wearables;
    
*   smart scales;
    
*   activity trackers;
    
*   laboratory providers;
    
*   spreadsheets;
    
*   manual records.
    

Each source has its own:

*   schema;
    
*   naming conventions;
    
*   units;
    
*   timestamps;
    
*   identifiers;
    
*   export format.
    

As a result, users accumulate years of data without having a reliable longitudinal record.

Typical problems include:

1.  The same metric appears under different names across sources.
    
2.  Units differ between exports.
    
3.  Source exports change over time.
    
4.  Historical files can contain corrections or deletions.
    
5.  Manual corrections are lost when imported data is rebuilt.
    
6.  High-frequency data creates unnecessary storage volume.
    
7.  Exercise names drift across applications.
    
8.  Retiring records from incomplete exports can silently destroy historical data.
    
9.  Dashboards show charts without preserving where values came from.
    

The platform must solve the historical data problem before solving the visualization problem.

3\. Product Vision
==================

Create a personal longitudinal health database that remains trustworthy even when:

*   the user changes devices;
    
*   the user changes applications;
    
*   vendors change export formats;
    
*   historical files are re-imported;
    
*   values require correction;
    
*   data is rebuilt using newer normalization logic.
    

The platform should eventually allow the user to answer questions such as:

*   Am I improving over time?
    
*   What changed compared with my historical baseline?
    
*   How has my body composition changed?
    
*   Is my strength progressing?
    
*   Are recovery metrics improving or deteriorating?
    
*   How consistent is my sleep?
    
*   What happened before and after a meaningful change?
    

The first requirement is that the underlying historical data must be trustworthy enough for those questions to have meaning.

4\. Product Principles
======================

4.1 Historical integrity over convenience
-----------------------------------------

The platform must prefer a reproducible and auditable historical record over shortcuts that make ingestion temporarily easier.

A value that cannot be traced or rebuilt is not trustworthy enough to become canonical history.

4.2 Universal ingestion surface
-------------------------------

The ingestion system supports structured files rather than building vendor-specific application pipelines.

The primary supported formats are:

*   CSV
    
*   XLSX
    

Vendor-specific behavior must be represented through import profiles and declarative mappings rather than hardcoded ingestion branches.

4.3 Source independence
-----------------------

The product must not depend on a particular health vendor for its architecture.

A user must be able to change from one application or device to another without rebuilding their entire historical data foundation.

4.4 Provenance is a product feature
-----------------------------------

Every canonical observation must be traceable to its originating raw record and import.

The system must support answering:

> Where did this value come from?

The provenance chain includes, where applicable:

*   source;
    
*   import;
    
*   original file;
    
*   raw record;
    
*   normalization version.
    

4.5 Reproducibility
-------------------

Historical data must be reproducible from its preserved ingestion history.

A rebuild using the same:

*   raw records;
    
*   mapping specification;
    
*   registry state;
    
*   normalization version;
    

must produce the same canonical result.

4.6 Corrections must survive rebuilds
-------------------------------------

Manual corrections must not be implemented as direct edits to canonical data.

A correction must become part of the ingestion history so that rebuilding the dataset preserves the corrected result.

4.7 Safety before destructive reconciliation
--------------------------------------------

Historical records must never be silently retired because a user imported an incomplete export.

Snapshot reconciliation must be guarded and require explicit confirmation before retirement occurs.

4.8 Registry-based identity
---------------------------

Metrics, exercises, activities, and custom events must have canonical identities.

Free-text source names may exist in raw data but must not become uncontrolled identifiers in canonical analytics.

5\. Target User
===============

The initial target user is a single individual who:

*   tracks health and performance across multiple systems;
    
*   exports historical data;
    
*   wants long-term trend analysis;
    
*   values historical continuity;
    
*   is willing to import structured files.
    

The MVP is a **single-user personal platform**.

Multi-user collaboration is explicitly outside the current scope.

6\. Core Product Requirements
=============================

6.1 Data Import
---------------

The product must allow users to import:

*   CSV files;
    
*   XLSX files.
    

The import workflow must support:

1.  file upload;
    
2.  file profiling;
    
3.  template selection;
    
4.  import profile matching;
    
5.  column mapping when necessary;
    
6.  data preview;
    
7.  user confirmation;
    
8.  background processing;
    
9.  progress tracking;
    
10.  import summary.
    

The application API must not synchronously parse large uploaded files.

Long-running imports must execute through resumable background jobs.

6.2 Universal Import Profiles
-----------------------------

The ingestion engine must support reusable import profiles.

An import profile defines:

*   source metadata;
    
*   template;
    
*   file detection rules;
    
*   mapping specification;
    
*   import mode;
    
*   snapshot scope;
    
*   retention overrides where applicable.
    

Profiles must be data-driven.

The ingestion engine must not contain vendor-specific branching such as:

Plain textANTLR4BashCC#CSSCoffeeScriptCMakeDartDjangoDockerEJSErlangGitGoGraphQLGroovyHTMLJavaJavaScriptJSONJSXKotlinLaTeXLessLuaMakefileMarkdownMATLABMarkupObjective-CPerlPHPPowerShell.propertiesProtocol BuffersPythonRRubySass (Sass)Sass (Scss)SchemeSQLShellSwiftSVGTSXTypeScriptWebAssemblyYAMLXML`   if source === vendor_name   `

Vendor-specific knowledge belongs in profile data and the approved transform library.

6.3 Supported Initial Domain
----------------------------

The first implemented vertical slice is strength training data.

The first supported real-world import profile is:

*   Hevy
    

The strength domain must support:

*   workouts;
    
*   exercises;
    
*   sets;
    
*   weight;
    
*   repetitions;
    
*   exercise identity;
    
*   workout timestamps;
    
*   source provenance.
    

The Hevy implementation is the first proof that the Universal Import Engine works.

It is not intended to become a special-case importer.

7\. Canonical Health Data Domains
=================================

The long-term product data model supports the following domains.

7.1 Body
--------

Examples include:

*   weight;
    
*   body fat percentage;
    
*   muscle mass;
    
*   lean mass;
    
*   body measurements.
    

7.2 Recovery
------------

Examples include:

*   resting heart rate;
    
*   heart rate variability;
    
*   recovery score;
    
*   respiratory rate;
    
*   blood oxygen.
    

7.3 Activity
------------

Examples include:

*   running;
    
*   cycling;
    
*   walking;
    
*   swimming;
    
*   hiking;
    
*   distance;
    
*   duration;
    
*   energy expenditure.
    

7.4 Strength
------------

Examples include:

*   workouts;
    
*   exercises;
    
*   sets;
    
*   repetitions;
    
*   resistance;
    
*   volume;
    
*   progression.
    

7.5 Sleep
---------

Sleep must be modeled as an event-level domain.

A sleep session may contain:

*   sleep start;
    
*   sleep end;
    
*   time in bed;
    
*   time asleep;
    
*   wake duration;
    
*   latency;
    
*   sleep stages;
    
*   efficiency;
    
*   disturbances.
    

Sleep consistency requires event-level sleep timing and cannot be derived solely from daily sleep duration.

7.6 Laboratory Data
-------------------

Laboratory observations may include:

*   analyte;
    
*   value;
    
*   unit;
    
*   reference range;
    
*   laboratory;
    
*   observation date.
    

Analytics must not present method-dependent laboratory results across incompatible laboratories as a falsely clean continuous trend.

7.7 Custom Events
-----------------

Custom events include structured events such as:

*   supplements;
    
*   medications;
    
*   treatments;
    
*   protocols.
    

Custom events must resolve to registered event definitions.

Arbitrary free-text event identifiers must not become canonical analytical entities.

8\. Manual Data Entry
=====================

The user must be able to manually enter selected measurements.

Initial manual-entry priorities include:

*   weight;
    
*   body fat percentage;
    
*   waist circumference;
    
*   other supported body measurements.
    

Manual data must use the same ingestion architecture as imported data.

Manual entry must:

1.  create a synthetic import;
    
2.  create one or more raw records;
    
3.  pass through normalization;
    
4.  create canonical observations through the normal write path.
    

Manual entry must not directly write into canonical measurement tables.

9\. Data Correction
===================

Users must be able to correct previously recorded values.

A correction must:

*   preserve the original historical record;
    
*   create a new ingestion record;
    
*   have higher precedence than the corrected observation;
    
*   deterministically supersede the previous value.
    

The corrected value must survive a complete normalization rebuild.

Direct application-level updates to canonical observations are prohibited.

10\. Import Modes
=================

The product must support at least two import modes.

10.1 Append
-----------

Append mode adds new observations without assuming the imported file represents a complete historical snapshot.

This must be the safe default unless the profile explicitly establishes otherwise.

10.2 Full Snapshot
------------------

Full snapshot mode treats an import as representing a defined scope of historical data.

The system may compare the incoming snapshot against existing records within that scope to detect:

*   additions;
    
*   corrections;
    
*   timestamp changes;
    
*   deletions.
    

Records missing from a complete snapshot may be candidates for retirement.

Retirement must remain subject to reconciliation guards and explicit user confirmation.

11\. Snapshot Safety Requirements
=================================

Snapshot reconciliation is potentially destructive and therefore requires safety controls.

The system must:

1.  calculate the proposed reconciliation impact;
    
2.  persist a reconciliation plan;
    
3.  evaluate safety guards;
    
4.  present the projected impact to the user;
    
5.  require explicit confirmation before retirement.
    

A truncated or materially incomplete export must not silently retire existing historical records.

The initial Hevy vertical slice must explicitly test this scenario.

If a deliberately truncated full-snapshot import causes retirement without the required guard behavior, the implementation does not pass its phase gate.

12\. Data Granularity Policy
============================

The platform does not treat all data at the same granularity.

12.1 Event-level data
---------------------

Event-level storage is required for domains where individual events carry analytical meaning.

Examples:

*   workouts;
    
*   exercises;
    
*   strength sets;
    
*   activities;
    
*   sleep sessions;
    
*   laboratory observations;
    
*   structured events.
    

12.2 Daily-level data
---------------------

Metrics already exported at daily resolution may be stored at daily resolution.

Examples include:

*   daily body weight;
    
*   daily HRV;
    
*   daily resting heart rate;
    
*   daily recovery score;
    
*   daily steps.
    

12.3 Reduced high-frequency data
--------------------------------

High-frequency data that the product only consumes at daily resolution may be reduced before canonical storage.

Examples may include:

*   minute-level heart rate;
    
*   continuous HRV samples;
    
*   intraday step samples;
    
*   continuous glucose monitoring data where no intraday feature exists.
    

Reduction must preserve enough provenance to explain the canonical daily value.

Original source files remain the authoritative retained source for reprocessing reduced imports.

13\. Original File Retention
============================

Every uploaded import file must be preserved in private storage.

Original file retention is required because:

*   imports may need to be rebuilt;
    
*   reduction logic may change;
    
*   future features may require different granularity;
    
*   provenance depends on the source artifact.
    

Files containing reduced high-frequency data are required for the lifetime of the active import because the reduced database representation alone cannot recreate the original samples.

The system must verify file integrity before file-based reprocessing.

14\. Analytics Requirements
===========================

The analytics layer must operate on canonical and derived data rather than directly interpreting arbitrary source files.

The initial analytics foundation must support trend visualization for:

*   weight;
    
*   body fat;
    
*   waist circumference;
    
*   HRV;
    
*   resting heart rate;
    
*   sleep.
    

Required time ranges:

*   7 days;
    
*   30 days;
    
*   90 days;
    
*   1 year;
    
*   all time.
    

Analytics must handle:

*   missing observations;
    
*   insufficient sample counts;
    
*   division by zero;
    
*   metric-specific gap policies.
    

The product must not fabricate continuity where observations are missing.

15\. Initial Product Success Criteria
=====================================

The product has successfully established its initial data foundation when it can demonstrate all of the following.

15.1 Authentication
-------------------

A user can:

*   sign up;
    
*   log in;
    
*   log out;
    
*   access protected application routes.
    

Users cannot access another user's records.

15.2 Registry foundation
------------------------

The system contains canonical registries for:

*   sources;
    
*   units;
    
*   unit conversions;
    
*   metrics;
    
*   metric aliases;
    
*   exercises;
    
*   exercise aliases;
    
*   activity types;
    
*   event definitions.
    

15.3 Strength import
--------------------

A real Hevy export can be:

1.  uploaded;
    
2.  profiled;
    
3.  matched to an import profile;
    
4.  processed;
    
5.  normalized into canonical workouts, exercises, and sets.
    

Every canonical row must retain provenance to the raw ingestion layer.

15.4 Snapshot safety
--------------------

A deliberately truncated copy of an existing full-history export must not silently retire historical records.

The system must:

*   detect the reconciliation impact;
    
*   apply the configured safety guard;
    
*   block unsafe retirement;
    
*   provide an append-only fallback where applicable.
    

This is a hard implementation gate.

15.5 Manual corrections
-----------------------

A user can correct a manually entered body measurement.

After a complete normalization rebuild, the corrected value must remain the resolved canonical value.

15.6 Analytics
--------------

The initial supported metrics can be visualized across the required historical ranges without:

*   resurrecting retired records;
    
*   fabricating missing observations;
    
*   failing on zero denominators;
    
*   treating insufficient observations as meaningful trends.
    

16\. Product Roadmap
====================

Phase 1 — Foundation
--------------------

Deliver:

*   application foundation;
    
*   authentication;
    
*   protected routes;
    
*   Supabase integration;
    
*   registry foundation;
    
*   RLS.
    

No mock health data.

Phase 2 — Data Foundation
-------------------------

Deliver:

*   import profiles;
    
*   imports;
    
*   background jobs;
    
*   immutable raw records;
    
*   import coverage;
    
*   canonical strength data structures;
    
*   natural keys;
    
*   revision strategy;
    
*   import modes;
    
*   constraints and indexes.
    

Phase 3 — First Vertical Slice
------------------------------

Deliver the complete Hevy import workflow.

The phase is not complete until:

*   a real export succeeds;
    
*   provenance is verified;
    
*   truncated snapshot retirement protection passes.
    

Phase 4 — Manual Body Tracking
------------------------------

Deliver:

*   manual body measurements;
    
*   synthetic imports;
    
*   correction through superseding raw records;
    
*   rebuild verification.
    

Phase 5 — Analytics Foundation
------------------------------

Deliver:

*   daily metric rollups;
    
*   incremental rollup processing;
    
*   initial historical charts;
    
*   missing-data handling;
    
*   observation safety checks.
    

17\. Explicitly Out of Scope for Phases 1–5
===========================================

The following must not be implemented during the initial five phases unless the product specification is explicitly amended:

*   Apple Health integration;
    
*   Garmin integration;
    
*   Oura integration;
    
*   Fitbit integration;
    
*   additional vendor verticals beyond Hevy;
    
*   AI or LLM features;
    
*   automated insight engine;
    
*   timeline engine;
    
*   cross-source entity resolution;
    
*   laboratory implementation;
    
*   sleep session implementation;
    
*   custom event implementation;
    
*   weekly rollup tables;
    
*   monthly rollup tables;
    
*   table partitioning;
    
*   multi-user collaboration UI;
    
*   mobile applications;
    
*   PDF ingestion;
    
*   OCR ingestion.
    

These are roadmap items, not implementation requirements for the current phases.

18\. Non-Goals
==============

The MVP is not intended to:

*   replace medical records;
    
*   diagnose disease;
    
*   provide medical advice;
    
*   act as a clinical decision system;
    
*   guarantee compatibility with every health-data vendor;
    
*   preserve every high-frequency sample indefinitely in Postgres;
    
*   automatically infer ambiguous identities without user confirmation.
    

The product is a personal historical data and analytics platform.

19\. Definition of Product Trust
================================

The product should be considered trustworthy only when a user can reasonably rely on the following chain:

Plain textANTLR4BashCC#CSSCoffeeScriptCMakeDartDjangoDockerEJSErlangGitGoGraphQLGroovyHTMLJavaJavaScriptJSONJSXKotlinLaTeXLessLuaMakefileMarkdownMATLABMarkupObjective-CPerlPHPPowerShell.propertiesProtocol BuffersPythonRRubySass (Sass)Sass (Scss)SchemeSQLShellSwiftSVGTSXTypeScriptWebAssemblyYAMLXML`   Original File        ↓  Import        ↓  Raw Record        ↓  Normalization        ↓  Canonical Observation        ↓  Rollup / Derived Data        ↓  Analytics   `

At every meaningful point, the system must be able to answer:

*   What produced this value?
    
*   Which source did it come from?
    
*   Which import created it?
    
*   Can the result be rebuilt?
    
*   Has it been retired?
    
*   Was it manually corrected?
    

If those questions cannot be answered reliably, the platform has not achieved its core purpose.

20\. Authority Boundary
=======================

This document defines **product requirements and expected behavior**.

Technical implementation authority is defined by:

*   docs/architecture/health-platform-architecture-v2.md
    
*   docs/architecture/health-platform-architecture-v3.md
    

Agent implementation behavior is governed by:

*   CLAUDE.md
    

Where a product requirement and architecture implementation detail appear to conflict, implementation must stop and request an explicit architectural ruling rather than silently choosing an interpretation.