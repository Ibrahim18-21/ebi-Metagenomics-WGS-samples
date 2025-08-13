#!/bin/bash

# =============================================
# CONFIGURATION (User Editable)
# =============================================
BED_DIR="cmsearch_results"         # Directory containing *_combined.bed files
FASTA_DIR="fasta_converted"       # Directory containing *_merged.fa files
OUTPUT_DIR="noncoding_sequences"  # Output directory for extracted sequences
THREADS=8                        # Number of CPU cores for parallel processing

# =============================================
# INITIALIZATION (Automated Setup)
# =============================================
mkdir -p "$OUTPUT_DIR"/{logs,samples} 
LOG_FILE="$OUTPUT_DIR/logs/processing.log"
exec > >(tee -a "$LOG_FILE") 2>&1  # Capture all output to log

echo "=== NON-CODING EXTRACTION STARTED $(date) ==="
echo "Configuration:"
echo "- BED Directory: $BED_DIR"
echo "- FASTA Directory: $FASTA_DIR"
echo "- Threads: $THREADS"

# =============================================
# MAIN PROCESSING FUNCTION
# =============================================
process_sample() {
    local bed_file="$1"
    local sample=$(basename "$bed_file" "_combined.bed")
    local fasta_file="$FASTA_DIR/${sample}.fa"
    local output_fasta="$OUTPUT_DIR/samples/${sample}_noncoding.fa"
    local sample_log="$OUTPUT_DIR/logs/${sample}.log"

    {
        echo "=== PROCESSING $sample ==="
        echo "- Input BED: $(basename "$bed_file")"
        echo "- Input FASTA: $(basename "$fasta_file")"

        if [[ ! -f "$fasta_file" ]]; then
            echo "ERROR: Missing FASTA file" >&2
            return 1
        fi

        echo "- Running bedtools getfasta..."
        if bedtools getfasta \
            -fi "$fasta_file" \
            -bed "$bed_file" \
            -fo "$output_fasta" \
            -name; then
            
            if [[ -s "$output_fasta" ]]; then
                local seq_count=$(grep -c '^>' "$output_fasta")
                echo "SUCCESS: Extracted $seq_count sequences"
                return 0
            else
                echo "WARNING: Empty output file generated" >&2
                rm -f "$output_fasta"
                return 1
            fi
        else
            echo "ERROR: bedtools failed" >&2
            rm -f "$output_fasta"
            return 1
        fi
    } > "$sample_log" 2>&1
}

# =============================================
# PARALLEL EXECUTION
# =============================================
export -f process_sample
export FASTA_DIR OUTPUT_DIR

echo -e "\n=== PROCESSING SAMPLES ==="
find "$BED_DIR" -name "*_combined.bed" -print0 | \
    xargs -0 -P "$THREADS" -I {} bash -c 'process_sample "{}"'

# =============================================
# RESULTS SUMMARY
# =============================================
success=$(find "$OUTPUT_DIR/samples" -name "*_noncoding.fa" | wc -l)
failures=$(grep -l "ERROR" "$OUTPUT_DIR/logs"/*.log 2>/dev/null | wc -l)

echo -e "\n=== FINAL REPORT ==="
echo "Successful samples: $success"
echo "Failed samples: $failures"
echo "Output directory: $OUTPUT_DIR/samples/"
echo "Log files: $OUTPUT_DIR/logs/"
echo "Total processing time: $SECONDS seconds"
