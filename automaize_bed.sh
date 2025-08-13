#!/bin/bash

# =============================================
# CONFIGURATION
# =============================================
OUTPUT_SUFFIX="_combined.bed"  # Output file naming
LOG_SUFFIX="_conversion.log"   # Log file naming

# =============================================
# MAIN PROCESSING
# =============================================

# Process all primary directories
find . -type d -name "*_primary" | while read -r dir; do
    # Extract base sample name (SRRXXXXXX)
    sample=$(basename "$dir" "_primary")
    output_bed="${dir}/${sample}${OUTPUT_SUFFIX}"
    log_file="${dir}/${sample}${LOG_SUFFIX}"
    
    echo "=== PROCESSING ${dir} ===" | tee "$log_file"
    echo "Sample: $sample" | tee -a "$log_file"
    echo "Output: $output_bed" | tee -a "$log_file"
    
    # Clear previous outputs
    > "$output_bed"
    > "$log_file"
    
    # Process all .tbl files
    file_count=0
    success_count=0
    
    for tbl_file in "${dir}"/*.tbl; do
        ((file_count++))
        echo " - File ${file_count}: $(basename "$tbl_file")" | tee -a "$log_file"
        
        # Convert with error capture
        if awk -v sample="$sample" -v file_num="$file_count" '
            BEGIN {OFS="\t"; errors=0}
            /^[^#]/ {
                if (NF >= 9) {  # Validate column count
                    if ($8 > $9) {
                        print $1, $9-1, $8, $3 "_" sample "_" file_num, "0", "-"
                    } else {
                        print $1, $8-1, $9, $3 "_" sample "_" file_num, "0", "+"
                    }
                } else {
                    print "ERROR: Insufficient columns in " FILENAME " line " NR > "/dev/stderr"
                    errors++
                }
            }
            END {exit errors}
        ' "$tbl_file" >> "$output_bed" 2>> "$log_file"; then
            ((success_count++))
            echo "   - Converted successfully" | tee -a "$log_file"
        else
            echo "   - FAILED (see log)" | tee -a "$log_file"
        fi
    done
    
    # Final status
    echo "Conversion complete:" | tee -a "$log_file"
    echo " - Files processed: ${file_count}" | tee -a "$log_file"
    echo " - Successful conversions: ${success_count}" | tee -a "$log_file"
    
    if [[ "$success_count" -eq 0 ]]; then
        echo "ERROR: No valid conversions for ${sample}" | tee -a "$log_file"
        rm "$output_bed"  # Remove empty output
    elif [[ -s "$output_bed" ]]; then
        echo "Output created: ${output_bed}" | tee -a "$log_file"
        echo "Entries: $(wc -l < "$output_bed")" | tee -a "$log_file"
    fi
    
    echo | tee -a "$log_file"
done

echo "All processing complete. Check individual *_conversion.log files."
