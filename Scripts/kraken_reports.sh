#!/bin/bash
set -euo pipefail

# =============================================
# CONFIGURATION
# =============================================
MAPSEQ_DIR="mapseq_results"
KRAKEN_REPORTS="kraken_reports"
THREADS=$(nproc --all || sysctl -n hw.ncpu)
mkdir -p "$KRAKEN_REPORTS"

# =============================================
# FUNCTIONS
# =============================================
process_otu_file() {
    local otu_file="$1"
    local sample=$(basename "$otu_file" .otu)
    
    # Input validation
    [[ ! -f "$otu_file" ]] && { echo "Error: $otu_file not found." >&2; return 1; }
    [[ $(wc -l < "$otu_file") -eq 0 ]] && { echo "Error: $otu_file is empty." >&2; return 1; }
    
    # Process file
    awk -v sample="$sample" '
    BEGIN {
        OFS = "\t";
        print "percentage\tclade_reads\ttaxon_reads\trank\ttaxon";
        total = 0;
    }
    /^#/ { next }  # Skip header line
    {
        # Clean taxonomy and sum counts
        taxon = $3;
        count = $4;
        taxon = gensub(/([a-z]__|_)/, " ", "g", taxon);  # Remove prefixes and underscores
        gsub(/;/, "; ", taxon);
        sub(/; $/, "", taxon);  # Fix trailing semicolon
        
        counts[taxon] += count;
        total += count;
    }
    END {
        if (total == 0) {
            print "100.00\t0\t0\t-\tNo_valid_taxa_found" > "/dev/stderr"
            exit 1;
        }
        for (t in counts) {
            printf "%.2f\t%d\t%d\t%s\t%s\n", 
                (counts[t]/total)*100, counts[t], counts[t], "-", t;
        }
    }' "$otu_file" > "${KRAKEN_REPORTS}/${sample}_kraken.txt"
    
    echo "Processed: $sample" >&2
}

export -f process_otu_file
export KRAKEN_REPORTS

# =============================================
# MAIN PROCESSING
# =============================================
echo "Starting conversion of OTU files to Kraken reports..."
TOTAL_FILES=$(find "$MAPSEQ_DIR" -name "*.otu" | wc -l)
echo "Found $TOTAL_FILES files to process using $THREADS threads."

find "$MAPSEQ_DIR" -name "*.otu" -print0 | xargs -0 -n1 -P"$THREADS" bash -c 'process_otu_file "$@"' _

# =============================================
# FINAL OUTPUT
# =============================================
echo "=== CONVERSION COMPLETE ==="
echo "Reports saved to: $KRAKEN_REPORTS/"
echo "Total generated: $(find "$KRAKEN_REPORTS" -name "*.txt" | wc -l)"
