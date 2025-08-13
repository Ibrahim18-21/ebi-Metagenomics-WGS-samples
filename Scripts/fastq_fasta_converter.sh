#!/bin/bash
set -euo pipefail

### ==================== ###
### USER CONFIGURATION   ###
### ==================== ###

# System Resources
MAX_PARALLEL_CONVERSIONS=4        # Number of files to convert simultaneously
THREADS_PER_CONVERSION=4           # CPU threads per seqkit process

# Input/Output Settings
INPUT_DIR="results_trim_merge_qc"                      # Directory containing FASTQ files
OUTPUT_DIR="./fasta_converted"     # Directory for FASTA outputs
TEMP_DIR="/tmp/fq2fa_$$"          # Temporary directory

# File Patterns
INPUT_PATTERN="*merged.fq.gz"     # Pattern to match input files
OUTPUT_SUFFIX=".fa"                # Extension for output files

# Processing Options
COMPRESS_OUTPUT=false              # Compress FASTA files (.fa.gz)
CLEANUP_TEMP=true                  # Remove temporary files
VALIDATE_CONVERSION=true           # Verify conversion success
PRESERVE_DESCRIPTION=true          # Keep full sequence descriptions

### ==================== ###
### HELPER FUNCTIONS     ###
### ==================== ###

check_dependencies() {
    echo "[$(date)] Checking dependencies..." | tee -a "$LOG_FILE"
    
    if ! command -v seqkit &> /dev/null; then
        echo "ERROR: seqkit not found in PATH. Please install seqkit." | tee -a "$LOG_FILE"
        exit 1
    fi
    
    local seqkit_version=$(seqkit version | head -1)
    echo "Found seqkit: $seqkit_version" | tee -a "$LOG_FILE"
}

validate_input_file() {
    local input_file="$1"
    
    if [[ ! -f "$input_file" ]] || [[ ! -r "$input_file" ]]; then
        echo "ERROR: Input file not accessible: $input_file"
        return 1
    fi
    
    if [[ ! -s "$input_file" ]]; then
        echo "ERROR: Input file is empty: $input_file"
        return 1
    fi
    
    # Quick format validation
    if ! seqkit stats "$input_file" &>/dev/null; then
        echo "ERROR: Invalid FASTQ format: $input_file"
        return 1
    fi
    
    return 0
}

convert_file() {
    local input_file="$1"
    local sample_name="$2"
    local output_file="$3"
    
    echo "[$(date)] Converting $sample_name" | tee -a "$LOG_FILE"
    
    # Validate input
    if ! validate_input_file "$input_file"; then
        echo "SKIPPING $sample_name due to validation errors" | tee -a "$LOG_FILE"
        return 1
    fi
    
    # Create temporary output path
    local temp_output="$TEMP_DIR/$(basename "$output_file")"
    local conversion_log="$OUTPUT_DIR/logs/${sample_name}_conversion.log"
    
    # Build seqkit command
    local seqkit_cmd=(
        seqkit
        fq2fa
        --threads "$THREADS_PER_CONVERSION"
    )
    
    # Add input and output
    seqkit_cmd+=("$input_file")
    
    # Execute conversion
    echo "[$(date)] Running seqkit fq2fa for $sample_name" >> "$conversion_log"
    if "${seqkit_cmd[@]}" > "$temp_output" 2>> "$conversion_log"; then
        
        # Validate conversion success
        if [ "$VALIDATE_CONVERSION" = true ]; then
            if [[ ! -s "$temp_output" ]]; then
                echo "ERROR: Conversion produced empty file for $sample_name" | tee -a "$LOG_FILE"
                return 1
            fi
            
            # Quick sequence count check
            local input_seqs=$(seqkit stats "$input_file" -T | tail -1 | cut -f4)
            local output_seqs=$(seqkit stats "$temp_output" -T | tail -1 | cut -f4)
            
            if [ "$input_seqs" -ne "$output_seqs" ]; then
                echo "WARNING: Sequence count mismatch for $sample_name (in: $input_seqs, out: $output_seqs)" | tee -a "$LOG_FILE"
            else
                echo "Validation passed: $output_seqs sequences converted" >> "$conversion_log"
            fi
        fi
        
        # Handle compression if requested
        if [ "$COMPRESS_OUTPUT" = true ]; then
            gzip "$temp_output"
            mv "${temp_output}.gz" "${output_file}.gz"
            echo "SUCCESS: $sample_name converted and compressed" | tee -a "$LOG_FILE"
        else
            mv "$temp_output" "$output_file"
            echo "SUCCESS: $sample_name converted" | tee -a "$LOG_FILE"
        fi
        
        return 0
    else
        echo "ERROR: seqkit conversion failed for $sample_name (see log)" | tee -a "$LOG_FILE"
        return 1
    fi
}

### ==================== ###
### MAIN EXECUTION       ###
### ==================== ###

# Create directories
mkdir -p "$OUTPUT_DIR/logs" "$TEMP_DIR"

# Initialize logging
LOG_FILE="$OUTPUT_DIR/logs/fq2fa_conversion.log"
echo "=== FASTQ TO FASTA CONVERSION STARTED $(date) ===" | tee "$LOG_FILE"
echo "Configuration:" | tee -a "$LOG_FILE"
echo "- Max parallel conversions: $MAX_PARALLEL_CONVERSIONS" | tee -a "$LOG_FILE"
echo "- Threads per conversion: $THREADS_PER_CONVERSION" | tee -a "$LOG_FILE"
echo "- Input directory: $INPUT_DIR" | tee -a "$LOG_FILE"
echo "- Output directory: $OUTPUT_DIR" | tee -a "$LOG_FILE"
echo "- Input pattern: $INPUT_PATTERN" | tee -a "$LOG_FILE"
echo "- Compress output: $COMPRESS_OUTPUT" | tee -a "$LOG_FILE"

# Check dependencies
check_dependencies

# Discover input files
declare -a conversion_jobs=()
echo "[$(date)] Discovering FASTQ files..." | tee -a "$LOG_FILE"

for input_file in $INPUT_DIR/$INPUT_PATTERN; do
    [[ ! -f "$input_file" ]] && continue
    
    # Extract sample name and create output filename
    sample_name=$(basename "$input_file" | sed 's/\.fq\.gz$//' | sed 's/\.fastq\.gz$//' | sed 's/_trimmed$//')
    output_file="$OUTPUT_DIR/${sample_name}${OUTPUT_SUFFIX}"
    
    if validate_input_file "$input_file"; then
        conversion_jobs+=("$input_file|$sample_name|$output_file")
        echo "✓ Queued for conversion: $sample_name" | tee -a "$LOG_FILE"
    else
        echo "✗ Skipping invalid file: $sample_name" | tee -a "$LOG_FILE"
    fi
done

# Check if any files found
if [ ${#conversion_jobs[@]} -eq 0 ]; then
    echo "ERROR: No valid FASTQ files found matching pattern: $INPUT_PATTERN" | tee -a "$LOG_FILE"
    exit 1
fi

echo "[$(date)] Found ${#conversion_jobs[@]} files to convert" | tee -a "$LOG_FILE"

# Process conversions
successful_conversions=0
failed_conversions=0

if [ "$MAX_PARALLEL_CONVERSIONS" -gt 1 ]; then
    echo "[$(date)] Starting parallel conversion (max: $MAX_PARALLEL_CONVERSIONS)" | tee -a "$LOG_FILE"
    
    for job_info in "${conversion_jobs[@]}"; do
        # Wait if at maximum parallel jobs
        while [ $(jobs -r | wc -l) -ge "$MAX_PARALLEL_CONVERSIONS" ]; do
            sleep 2
        done
        
        IFS='|' read -r input_file sample_name output_file <<< "$job_info"
        
        # Run conversion in background
        {
            if convert_file "$input_file" "$sample_name" "$output_file"; then
                echo "SUCCESS: $sample_name" >> "$OUTPUT_DIR/logs/conversion_status.tmp"
            else
                echo "FAILED: $sample_name" >> "$OUTPUT_DIR/logs/conversion_status.tmp"
            fi
        } &
    done
    
    # Wait for all conversions to complete
    wait
    
    # Count results
    if [[ -f "$OUTPUT_DIR/logs/conversion_status.tmp" ]]; then
        successful_conversions=$(grep -c "SUCCESS:" "$OUTPUT_DIR/logs/conversion_status.tmp" || echo 0)
        failed_conversions=$(grep -c "FAILED:" "$OUTPUT_DIR/logs/conversion_status.tmp" || echo 0)
        rm "$OUTPUT_DIR/logs/conversion_status.tmp"
    fi
    
else
    echo "[$(date)] Starting sequential conversion" | tee -a "$LOG_FILE"
    
    for job_info in "${conversion_jobs[@]}"; do
        IFS='|' read -r input_file sample_name output_file <<< "$job_info"
        
        if convert_file "$input_file" "$sample_name" "$output_file"; then
            ((successful_conversions++))
        else
            ((failed_conversions++))
        fi
    done
fi

# Cleanup
if [ "$CLEANUP_TEMP" = true ]; then
    echo "[$(date)] Cleaning up temporary files" | tee -a "$LOG_FILE"
    rm -rf "$TEMP_DIR"
fi

# Final summary
echo "=== CONVERSION COMPLETED ===" | tee -a "$LOG_FILE"
echo "Summary:" | tee -a "$LOG_FILE"
echo "- Total files processed: ${#conversion_jobs[@]}" | tee -a "$LOG_FILE"
echo "- Successful conversions: $successful_conversions" | tee -a "$LOG_FILE"
echo "- Failed conversions: $failed_conversions" | tee -a "$LOG_FILE"
echo "- Output directory: $OUTPUT_DIR" | tee -a "$LOG_FILE"
echo "- Conversion completed: $(date)" | tee -a "$LOG_FILE"

# Exit with appropriate status
if [ "$failed_conversions" -gt 0 ]; then
    echo "WARNING: Some conversions failed. Check individual logs." | tee -a "$LOG_FILE"
    exit 2
else
    echo "SUCCESS: All files converted successfully!" | tee -a "$LOG_FILE"
    exit 0
fi
