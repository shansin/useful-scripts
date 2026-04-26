#!/bin/bash

echo "--- Thermal Dashboard ($(date '+%H:%M:%S')) ---"

# Use a function to format sections consistently
format_output() {
    column -t -s $'\t'
}

{
    # 1. Motherboard & CPU
    echo -e "[ Motherboard & CPU ]\t"
    sensors | awk -F: '/^(CPU:|T_Sensor:|CPU Package:|VRM:|Motherboard:)/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print "  "$1 "\t" $2}'
    
    # 2. AMD GPU
    echo -e "\n[ AMD GPU ]\t"
    sensors | awk '/amdgpu-pci-7a00/,/sclk/ {if ($1=="edge:") print "  GPU Temp:\t" $2}'

    # 3. NVIDIA GPUs
    echo -e "\n[ NVIDIA GPUs ]\t"
    nvidia-smi --query-gpu=index,name,temperature.gpu --format=csv,noheader,nounits | \
    awk -F', ' '{print "  GPU " $1 " (" $2 "):\t" $3 "°C"}'

    # 4. Storage (NVMe)
    echo -e "\n[ NVMe Storage ]\t"
    sensors | awk '/nvme-pci/ {dev=$1} /Composite:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print "  " dev ":\t" $2}'

    # 5. Fans
    echo -e "\n[ Fans ]\t"
    sensors | awk -F: '/RPM/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print "  " $1 "\t" $2}'

    # 6. NVIDIA GPU Fans
    nvidia-smi --query-gpu=index,name,fan.speed --format=csv,noheader,nounits 2>/dev/null | \
    awk -F', ' '$3 != "[N/A]" {print "  GPU " $1 " Fan (" $2 "):\t" $3 " %"}'

} | column -t -s $'\t'

echo "------------------------------------------"
