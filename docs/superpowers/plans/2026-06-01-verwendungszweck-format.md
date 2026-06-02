# Verwendungszweck Format Change Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Change the Verwendungszweck in generated emails (print and QR code) from just the reference number to the format `"<event_name> - <first_name> <last_name> - <ref_without_underscores>"`.

**Architecture:** Add a `format_verwendungszweck` helper in `ConfirmationEmails.jl`, thread it through `generate_email_content` to both `prepare_bank_details` and `maybe_generate_payment_qr`, and add no-underscore reference matching to `find_reference_in_text` in `ReferenceNumbers.jl`.

**Tech Stack:** Julia 1.12+, DuckDB, QRCode.jl, EPC/SEPA QR format

---

### Task 1: Add `format_verwendungszweck` helper and update `generate_email_content`

**Files:**
- Modify: `src/ConfirmationEmails.jl`

- [ ] **Step 1: Write a failing test**

Add to `test/runtests.jl` in the `ConfirmationEmails` section (or add a new `@testset`):

```julia
@testset "format_verwendungszweck" begin
    using EventRegistrations: format_verwendungszweck
    @test format_verwendungszweck("PWE Chor Brahms", "Max", "Mustermann", "PWE_2026_02_001") ==
          "PWE Chor Brahms - Max Mustermann - PWE202602001"
    # Underscores stripped from reference only
    @test format_verwendungszweck("Workshop Weekend", "Anna", "Schmidt", "WS_2025_01_042") ==
          "Workshop Weekend - Anna Schmidt - WS202501042"
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
julia --project -e 'using Pkg; Pkg.test()' 2>&1 | grep -A3 "format_verwendungszweck"
```
Expected: `UndefVarError: format_verwendungszweck not defined`

- [ ] **Step 3: Add the helper function in `src/ConfirmationEmails.jl`**

Add immediately before `prepare_bank_details` (around line 144):

```julia
"""
Format the Verwendungszweck string for bank transfers and QR codes.
Format: "<event_name> - <first_name> <last_name> - <ref_without_underscores>"
Example: "PWE Chor Brahms - Max Mustermann - PWE202602001"
"""
function format_verwendungszweck(event_name::String, first_name::String, last_name::String, reference_number::String)
    ref_clean = replace(reference_number, "_" => "")
    return "$(event_name) - $(first_name) $(last_name) - $(ref_clean)"
end
```

Also add it to the module exports at the top of the file if there is an explicit export list, or add to the main `EventRegistrations.jl` re-exports as needed.

- [ ] **Step 4: Run test to verify it passes**

```bash
julia --project -e 'using Pkg; Pkg.test()' 2>&1 | grep -A3 "format_verwendungszweck"
```
Expected: `Test Passed`

- [ ] **Step 5: Commit**

```bash
git add src/ConfirmationEmails.jl test/runtests.jl
git commit -m "feat: add format_verwendungszweck helper"
```

---

### Task 2: Update `generate_sepa_qr_payload` and `maybe_generate_payment_qr`

**Files:**
- Modify: `src/ConfirmationEmails.jl`

- [ ] **Step 1: Update `generate_sepa_qr_payload` to allow 140-char unstructured remittance**

The current code caps `remittance` at 70 chars (line ~206). Change it to 140 per the EPC standard:

```julia
# Old:
remittance[1:min(end, 70)]
# New:
remittance[1:min(end, 140)]
```

- [ ] **Step 2: Update `maybe_generate_payment_qr` signature to accept `verwendungszweck`**

Change the function signature from:
```julia
function maybe_generate_payment_qr(cfg::EmailConfig, amount::Float64, reference::String)
```
to:
```julia
function maybe_generate_payment_qr(cfg::EmailConfig, amount::Float64, reference::String, verwendungszweck::String="")
```

Update the `generate_sepa_qr_payload` call inside it. Replace:
```julia
payload = generate_sepa_qr_payload(
    amount = amount,
    reference = string(strip(reference)),
    recipient = cfg.account_name,
    iban = cfg.iban,
    bic = cfg.bic,
    remittance = isempty(cfg.qr_message) ? cfg.bank_name : cfg.qr_message
)
```
with:
```julia
qr_remittance = isempty(verwendungszweck) ?
    (isempty(cfg.qr_message) ? cfg.bank_name : cfg.qr_message) :
    verwendungszweck
payload = generate_sepa_qr_payload(
    amount = amount,
    reference = string(strip(reference)),
    recipient = cfg.account_name,
    iban = cfg.iban,
    bic = cfg.bic,
    remittance = qr_remittance
)
```

- [ ] **Step 3: Update `generate_email_content` to compute and pass Verwendungszweck**

In `generate_email_content` (around line 303), replace:
```julia
bank_details_text = prepare_bank_details(cfg, reference_number)
```
with:
```julia
verwendungszweck = format_verwendungszweck(event_name, first_name, last_name, reference_number)
bank_details_text = prepare_bank_details(cfg, verwendungszweck)
```

And replace (around line 326):
```julia
qr_html = maybe_generate_payment_qr(cfg, to_float(remaining), reference_number)
```
with:
```julia
qr_html = maybe_generate_payment_qr(cfg, to_float(remaining), reference_number, verwendungszweck)
```

- [ ] **Step 4: Run tests**

```bash
julia --project -e 'using Pkg; Pkg.test()'
```
Expected: All tests pass. Any test that checks email content / bank details text will now see the new Verwendungszweck format.

- [ ] **Step 5: Commit**

```bash
git add src/ConfirmationEmails.jl
git commit -m "feat: use format_verwendungszweck in QR code and bank details"
```

---

### Task 3: Add no-underscore pattern to `find_reference_in_text`

**Files:**
- Modify: `src/ReferenceNumbers.jl`

- [ ] **Step 1: Write a failing test**

Add to the reference number tests in `test/runtests.jl`:

```julia
@testset "find_reference_in_text no-underscore format" begin
    using EventRegistrations: find_reference_in_text
    # Full Verwendungszweck string with concatenated reference
    @test find_reference_in_text("PWE Chor Brahms - Max Mustermann - PWE202602001") == "PWE_2026_02_001"
    # Just the concatenated reference alone
    @test find_reference_in_text("PWE202601042") == "PWE_2026_01_042"
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
julia --project -e 'using Pkg; Pkg.test()' 2>&1 | grep -A5 "find_reference_in_text no-underscore"
```
Expected: test returns `nothing` instead of the expected reference.

- [ ] **Step 3: Add Pattern 5 to `find_reference_in_text` in `src/ReferenceNumbers.jl`**

After Pattern 3 (the spaces pattern, around line 75), add:

```julia
# Pattern 4: Concatenated without separators (e.g. PWE202602001 -> PWE_2026_02_001)
# Matches: 2-6 uppercase letters + 4-digit year + 2-digit month-index + 3-digit ID
m = match(r"([A-Z]{2,6})(\d{4})(\d{2})(\d{3})\b", text_upper)
if m !== nothing
    event_prefix, year, month, num = m.captures
    return "$(event_prefix)_$(year)_$(month)_$(num)"
end
```

- [ ] **Step 4: Run test to verify it passes**

```bash
julia --project -e 'using Pkg; Pkg.test()' 2>&1 | grep -A5 "find_reference_in_text no-underscore"
```
Expected: `Test Passed`

- [ ] **Step 5: Run full test suite**

```bash
julia --project -e 'using Pkg; Pkg.test()'
```
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/ReferenceNumbers.jl test/runtests.jl
git commit -m "feat: match no-underscore reference format in find_reference_in_text"
```
