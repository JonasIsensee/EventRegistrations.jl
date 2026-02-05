# Scrollable Pager for Table Display

## Overview

The EventRegistrations.jl package now supports displaying tables in a scrollable pager with full horizontal and vertical scrolling capabilities. This is especially useful for wide tables with long email addresses or many columns.

## Features

- **Horizontal Scrolling**: View full table width without truncation
- **Vertical Scrolling**: Navigate through large tables easily
- **Color Preservation**: All colors and formatting are maintained in the pager
- **Full Email Display**: When using the pager, email addresses are shown in full (not truncated)
- **Easy Navigation**: Uses the standard `less` pager with familiar keyboard shortcuts

## Usage

### CLI Commands

Add the `--pager` flag to any table display command:

```bash
# List registrations with pager
eventreg list-registrations --pager

# Export payment status with pager
eventreg export-payment-status --pager

# Export registrations with pager
eventreg export-registrations --pager

# Combine with other flags
eventreg list-registrations --filter=unpaid --pager
eventreg export-payment-status --filter=problems --pager
```

## Pager Navigation

When the pager is active, you can use these keyboard shortcuts:

- **Up/Down Arrow** or **j/k**: Scroll vertically one line at a time
- **Left/Right Arrow** or **h/l**: Scroll horizontally
- **Page Up/Page Down** or **Space/b**: Scroll one page at a time
- **g/G**: Jump to beginning/end of document
- **/text**: Search for text
- **q**: Quit the pager

## Requirements

- Unix-like system with `less` installed (standard on Linux and macOS)
- Works in terminal environments that support TTY
