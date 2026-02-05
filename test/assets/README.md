# Test Assets

This directory contains immutable test data files used by the test suite.

## Structure

- `emails/` - Sample email files (.eml) with registration submissions
- `events/` - Event configuration files (.toml)
- `bank_transfers/` - Sample bank transfer CSV files
- `templates/` - Email templates (Mustache format)
- `credentials.toml` - Sample credentials configuration

## Usage

During test execution, these files are copied to a temporary directory created with `mktempdir()`.
All test operations are performed in the temporary directory to ensure:
1. Tests don't modify the source assets
2. Tests don't leave artifacts in the repository
3. Each test run starts with a clean state

## Do Not Modify

These files should remain immutable reference data. If you need different test data,
either:
- Create it programmatically in the test suite (preferred)
- Add new files here only if they're needed across multiple tests
