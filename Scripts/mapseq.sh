#!/bin/bash
set -euo pipefail

### ==================== ###
### USER CONFIGURATION   ###
### ==================== ###

# System Resources
THREADS=8                           # Threads per MapSeq process
MAX_PARALLEL_SAMPLES=3              # Number of samples to process simultaneously  
MAX_PARALLEL_DATABASES=2            # SSU and LSU can run in parallel per sample

# Directory Structure
REF_DIR="ref-dbs"
NONCODING_DIR="noncoding_sequences/samples"
OUTPUT_DIR="mapseq_results"
TEMP_DIR="/tmp/mapseq_$$"

# Database Paths
SSU_DB="${REF_DIR}/silva_ssu-20200130/SSU.fasta"
LSU_DB="${REF_DIR}/silva_lsu-20200130/LSU.fasta"
SSU_TAXONOMY="${REF_DIR}/silva_ssu-20200130/slv_ssu_filtered2.txt"
LSU_TAXONOMY="${REF_DIR}/silva_lsu-20200130/slv_lsu_filtered2.txt"

# Processing Options
CLEANUP_TEMP=true                   # Remove temporary files
VALIDATE_OUTPUTS=true               # Check output file integrity
COMPRESS_OUTPUTS=false              # Compress result files
CREATE_SUMMARY=true                 # Generate final summary report

### ==================== ###
### HELPER FUNCTIONS     ###
### ==================== ###

check_dependencies() {
    echo "[$(date)] Checking dependencies..." | tee -a "$LOG_FILE"
    
    # Check MapSeq
    if ! command -v mapseq &> /dev/null; then
        echo "ERROR: mapseq not found in PATH" | tee -a "$LOG_FILE"
        exit 1
    fi
    
    # Check reference databases
    local missing_files=()
    [[ ! -f "$SSU_DB" ]] && missing_files+=("SSU database: $SSU_DB")
    [[ ! -f "$LSU_DB" ]] && missing_files+=("LSU database: $LSU_DB") 
    [[ ! -f "$SSU_TAXONOMY" ]] && missing_files+=("SSU taxonomy: $SSU_TAXONOMY")
    [[ ! -f "$LSU_TAXONOMY" ]] && missing_files+=("LSU taxonomy: $LSU_TAXONOMY")
    
    if [ ${#missing_files[@]} -gt 0 ]; then
        echo "ERROR: Missing reference files:" | tee -a "$LOG_FILE"
        printf '%s\n' "${missing_files[@]}" | tee -a "$LOG_FILE"
        exit 1
    fi
    
    echo "All dependencies and databases found" | tee -a "$LOG_FILE"
}

validate_sample_file() {
    local sample_file="$1"
    
    if [[ ! -f "$sample_file" ]] || [[ ! -r "$sample_file" ]]; then
        echo "ERROR: Sample file not accessible: $sample_file"
        return 1
    fi
    
    if [[ ! -s "$sample_file" ]]; then
        echo "ERROR: Sample file is empty: $sample_file"
        return 1
    fi
    
    # Quick FASTA format check
    if ! head -1 "$sample_file" | grep -q "^>"; then
        echo "ERROR: File doesn't appear to be FASTA format: $sample_file"
        return 1
    fi
    
    return 0
}

process_database() {
    local sample="$1"
    local database_type="$2"  # "ssu" or "lsu"
    local sample_file="$3"
    
    local db_file taxonomy_file output_prefix
    
    # Set database-specific parameters
    if [[ "$database_type" == "ssu" ]]; then
        db_file="$SSU_DB"
        taxonomy_file="$SSU_TAXONOMY"
        output_prefix="${sample}_ssu"
    elif [[ "$database_type" == "lsu" ]]; then
        db_file="$LSU_DB"
        taxonomy_file="$LSU_TAXONOMY"
        output_prefix="${sample}_lsu"
    else
        echo "ERROR: Unknown database type: $database_type"
        return 1
    fi
    
    local temp_dir="$TEMP_DIR/${sample}"
    local mapseq_output="$temp_dir/${output_prefix}.mapseq"
    local otu_output="$temp_dir/${output_prefix}.otu"
    local log_file="$OUTPUT_DIR/logs/${output_prefix}.log"
    
    mkdir -p "$temp_dir"
    
    echo "[$(date)] Processing $sample against $database_type database" >> "$log_file"
    
    # Run MapSeq classification
    if mapseq \
        "$sample_file" \
        "$db_file" \
        "$taxonomy_file" \
        > "$mapseq_output" \
        2>> "$log_file"; then
        
        # Generate OTU counts
        if mapseq -otucounts "$mapseq_output" > "$otu_output" 2>> "$log_file"; then
            
            # Move results to final location
            mv "$mapseq_output" "$OUTPUT_DIR/"
            mv "$otu_output" "$OUTPUT_DIR/"
            
            # Validate outputs if requested
            if [ "$VALIDATE_OUTPUTS" = true ]; then
                if [[ -s "$OUTPUT_DIR/$(basename "$mapseq_output")" ]] && \
                   [[ -s "$OUTPUT_DIR/$(basename "$otu_output")" ]]; then
                    echo "SUCCESS: $sample $database_type processing completed" >> "$log_file"
                    return 0
                else
                    echo "ERROR: $sample $database_type produced empty outputs" >> "$log_file"
                    return 1
                fi
            else
                echo "SUCCESS: $sample $database_type processing completed" >> "$log_file"
                return 0
            fi
        else
            echo "ERROR: $sample $database_type OTU counting failed" >> "$log_file"
            return 1
        fi
    else
        echo "ERROR: $sample $database_type MapSeq classification failed" >> "$log_file"
        return 1
    fi
}

process_sample() {
    local sample="$1"
    local sample_file="$NONCODING_DIR/${sample}_noncoding.fa"
    
    echo "[$(date)] Starting processing for sample: $sample" | tee -a "$LOG_FILE"
    
    # Validate sample file
    if ! validate_sample_file "$sample_file"; then
        echo "SKIPPING $sample due to file validation errors" | tee -a "$LOG_FILE"
        return 1
    fi
    
    local success_count=0
    local total_databases=2
    
    if [ "$MAX_PARALLEL_DATABASES" -gt 1 ]; then
        # Process databases in parallel
        echo "[$(date)] Processing $sample databases in parallel" | tee -a "$LOG_FILE"
        
        # Start both database processing in background
        process_database "$sample" "ssu" "$sample_file" &
        local ssu_pid=$!
        
        process_database "$sample" "lsu" "$sample_file" &
        local lsu_pid=$!
        
        # Wait for both to complete and check results
        if wait $ssu_pid; then
            ((success_count++))
            echo "✓ $sample SSU completed successfully" | tee -a "$LOG_FILE"
        else
            echo "✗ $sample SSU failed" | tee -a "$LOG_FILE"
        fi
        
        if wait $lsu_pid; then
            ((success_count++))
            echo "✓ $sample LSU completed successfully" | tee -a "$LOG_FILE"
        else
            echo "✗ $sample LSU failed" | tee -a "$LOG_FILE"
        fi
        
    else
        # Process databases sequentially
        echo "[$(date)] Processing $sample databases sequentially" | tee -a "$LOG_FILE"
        
        if process_database "$sample" "ssu" "$sample_file"; then
            ((success_count++))
            echo "✓ $sample SSU completed" | tee -a "$LOG_FILE"
        else
            echo "✗ $sample SSU failed" | tee -a "$LOG_FILE"
        fi
        
        if process_database "$sample" "lsu" "$sample_file"; then
            ((success_count++))
            echo "✓ $sample LSU completed" | tee -a "$LOG_FILE"
        else
            echo "✗ $sample LSU failed" | tee -a "$LOG_FILE"
        fi
    fi
    
    # Clean up sample temp directory
    if [ "$CLEANUP_TEMP" = true ]; then
        rm -rf "$TEMP_DIR/${sample}"
    fi
    
    echo "[$(date)] Sample $sample completed: $success_count/$total_databases databases successful" | tee -a "$LOG_FILE"
    
    if [ "$success_count" -gt 0 ]; then
        return 0
    else
        return 1
    fi
}

generate_summary() {
    local summary_file="$OUTPUT_DIR/pipeline_summary.txt"
    
    echo "=== MAPSEQ PIPELINE SUMMARY ===" > "$summary_file"
    echo "Generated: $(date)" >> "$summary_file"
    echo "" >> "$summary_file"
    
    echo "CONFIGURATION:" >> "$summary_file"
    echo "- Threads per process: $THREADS" >> "$summary_file"
    echo "- Max parallel samples: $MAX_PARALLEL_SAMPLES" >> "$summary_file"
    echo "- Max parallel databases: $MAX_PARALLEL_DATABASES" >> "$summary_file"
    echo "- Input directory: $NONCODING_DIR" >> "$summary_file"
    echo "- Output directory: $OUTPUT_DIR" >> "$summary_file"
    echo "" >> "$summary_file"
    
    echo "RESULTS:" >> "$summary_file"
    echo "SSU Results:" >> "$summary_file"
    ls -la "$OUTPUT_DIR"/*_ssu.otu 2>/dev/null | wc -l | xargs echo "- OTU files:" >> "$summary_file"
    
    echo "LSU Results:" >> "$summary_file"
    ls -la "$OUTPUT_DIR"/*_lsu.otu 2>/dev/null | wc -l | xargs echo "- OTU files:" >> "$summary_file"
    
    echo "" >> "$summary_file"
    echo "OUTPUT FILES:" >> "$summary_file"
    echo "Individual results:" >> "$summary_file"
    ls -la "$OUTPUT_DIR"/*.otu 2>/dev/null | awk '{print "- " $9 " (" $5 " bytes)"}' >> "$summary_file"
    
    echo "" >> "$summary_file"
    echo "For detailed logs, check: $OUTPUT_DIR/logs/" >> "$summary_file"
}

### ==================== ###
### MAIN EXECUTION       ###
### ==================== ###

# Create directory structure
mkdir -p "$OUTPUT_DIR/logs" "$TEMP_DIR"

# Initialize logging
LOG_FILE="$OUTPUT_DIR/logs/mapseq_pipeline.log"
echo "=== MAPSEQ PARALLEL PIPELINE STARTED $(date) ===" | tee "$LOG_FILE"
echo "Configuration:" | tee -a "$LOG_FILE"
echo "- Threads per MapSeq: $THREADS" | tee -a "$LOG_FILE"
echo "- Max parallel samples: $MAX_PARALLEL_SAMPLES" | tee -a "$LOG_FILE"
echo "- Max parallel databases per sample: $MAX_PARALLEL_DATABASES" | tee -a "$LOG_FILE"
echo "- Input directory: $NONCODING_DIR" | tee -a "$LOG_FILE"
echo "- Output directory: $OUTPUT_DIR" | tee -a "$LOG_FILE"

# Check dependencies and databases
check_dependencies

# Discover samples
echo "[$(date)] Discovering samples..." | tee -a "$LOG_FILE"
mapfile -t samples < <(find "$NONCODING_DIR" -name "*_noncoding.fa" | xargs -n1 basename | sed 's/_noncoding.fa//')

if [ ${#samples[@]} -eq 0 ]; then
    echo "ERROR: No sample files found in $NONCODING_DIR" | tee -a "$LOG_FILE"
    echo "Expected files: *_noncoding.fa" | tee -a "$LOG_FILE"
    exit 1
fi

echo "[$(date)] Found ${#samples[@]} samples to process" | tee -a "$LOG_FILE"

# Process samples with parallelization
successful_samples=0
failed_samples=0

if [ "$MAX_PARALLEL_SAMPLES" -gt 1 ]; then
    echo "[$(date)] Processing samples in parallel (max: $MAX_PARALLEL_SAMPLES)" | tee -a "$LOG_FILE"
    
    for sample in "${samples[@]}"; do
        # Wait if at maximum parallel processes
        while [ $(jobs -r | wc -l) -ge "$MAX_PARALLEL_SAMPLES" ]; do
            sleep 5
        done
        
        # Process sample in background
        {
            if process_sample "$sample"; then
                echo "SUCCESS: $sample" >> "$OUTPUT_DIR/logs/sample_status.tmp"
            else
                echo "FAILED: $sample" >> "$OUTPUT_DIR/logs/sample_status.tmp"
            fi
        } &
    done
    
    # Wait for all samples to complete
    wait
    
    # Count results
    if [[ -f "$OUTPUT_DIR/logs/sample_status.tmp" ]]; then
        successful_samples=$(grep -c "SUCCESS:" "$OUTPUT_DIR/logs/sample_status.tmp" || echo 0)
        failed_samples=$(grep -c "FAILED:" "$OUTPUT_DIR/logs/sample_status.tmp" || echo 0)
        rm "$OUTPUT_DIR/logs/sample_status.tmp"
    fi
    
else
    echo "[$(date)] Processing samples sequentially" | tee -a "$LOG_FILE"
    
    for sample in "${samples[@]}"; do
        if process_sample "$sample"; then
            ((successful_samples++))
        else
            ((failed_samples++))
        fi
    done
fi

# Final cleanup
if [ "$CLEANUP_TEMP" = true ]; then
    echo "[$(date)] Final cleanup of temporary files" | tee -a "$LOG_FILE"
    rm -rf "$TEMP_DIR"
fi

# Generate summary report
if [ "$CREATE_SUMMARY" = true ]; then
    echo "[$(date)] Generating summary report" | tee -a "$LOG_FILE"
    generate_summary
fi

# Final report
echo "=== MAPSEQ PIPELINE COMPLETED ===" | tee -a "$LOG_FILE"
echo "Processing Summary:" | tee -a "$LOG_FILE"
echo "- Total samples: ${#samples[@]}" | tee -a "$LOG_FILE"
echo "- Successful samples: $successful_samples" | tee -a "$LOG_FILE"
echo "- Failed samples: $failed_samples" | tee -a "$LOG_FILE"
echo "- Results directory: $OUTPUT_DIR" | tee -a "$LOG_FILE"
echo "- Individual OTU files: $OUTPUT_DIR/*.otu" | tee -a "$LOG_FILE"
echo "- Individual MapSeq files: $OUTPUT_DIR/*.mapseq" | tee -a "$LOG_FILE"
echo "- Summary report: $OUTPUT_DIR/pipeline_summary.txt" | tee -a "$LOG_FILE"
echo "- Pipeline finished: $(date)" | tee -a "$LOG_FILE"

# Exit with appropriate status
if [ "$failed_samples" -gt 0 ]; then
    echo "WARNING: Some samples failed processing. Check logs for details." | tee -a "$LOG_FILE"
    exit 2
else
    echo "SUCCESS: All samples processed successfully!" | tee -a "$LOG_FILE"
    exit 0
fi
