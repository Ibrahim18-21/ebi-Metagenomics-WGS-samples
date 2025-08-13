#!/bin/bash
set -euo pipefail

# =============================================
# CONFIGURATION
# =============================================
KRAKEN_REPORTS="kraken_reports"      # Input directory (from previous step)
KRONA_OUTPUT="krona_results"         # Output directory
THREADS=$(nproc --all || sysctl -n hw.ncpu)  # Dynamic core detection
LOG_DIR="$KRONA_OUTPUT/logs"         # Centralized logging

# =============================================
# INITIALIZATION
# =============================================
mkdir -p "$KRONA_OUTPUT" "$LOG_DIR"

# Clear previous logs (if any)
:> "$LOG_DIR/success.log"
:> "$LOG_DIR/errors.log"

# =============================================
# FUNCTIONS
# =============================================
process_kraken_report() {
    local report="$1"
    local sample=$(basename "$report" _kraken.txt)
    local output="$KRONA_OUTPUT/${sample}_krona.html"
    
    echo "[$(date +'%T')] Processing: $sample" >&2
    
    # Generate Krona plot
    if ! ktImportText "$report" -o "$output" 2>> "$LOG_DIR/ktImportText_errors.log"; then
        echo "FAILED: $sample" >> "$LOG_DIR/errors.log"
        return 1
    fi
    
    # Validate output
    if [[ -f "$output" ]]; then
        echo "SUCCESS: $sample" >> "$LOG_DIR/success.log"
    else
        echo "ERROR: Output not generated for $sample" >> "$LOG_DIR/errors.log"
        return 1
    fi
}

export -f process_kraken_report
export KRONA_OUTPUT LOG_DIR

# =============================================
# MAIN PROCESSING
# =============================================
echo "Starting Krona visualization with $THREADS threads..."
TOTAL_FILES=$(find "$KRAKEN_REPORTS" -name "*_kraken.txt" | wc -l)
echo "Found $TOTAL_FILES Kraken reports to process."

# Process files in parallel
find "$KRAKEN_REPORTS" -name "*_kraken.txt" -print0 | \
    xargs -0 -P "$THREADS" -I {} bash -c 'process_kraken_report "$@"' _ {}

# =============================================
# SUMMARY & VALIDATION
# =============================================
SUCCESS_COUNT=$(wc -l < "$LOG_DIR/success.log" 2>/dev/null || echo 0)
FAILED_COUNT=$(wc -l < "$LOG_DIR/errors.log" 2>/dev/null || echo 0)

{
    echo "=== KRONA VISUALIZATION SUMMARY ==="
    echo "Date: $(date)"
    echo "Output directory: $KRONA_OUTPUT"
    echo "Total processed: $TOTAL_FILES"
    echo "Successful: $SUCCESS_COUNT"
    echo "Failed: $FAILED_COUNT"
    [[ "$FAILED_COUNT" -gt 0 ]] && \
        echo "WARNING: Check $LOG_DIR/errors.log for details"
} | tee "$KRONA_OUTPUT/summary.log"

# Exit with error if any failures occurred
[[ "$FAILED_COUNT" -gt 0 ]] && exit 1 || exit 0
