#!/bin/bash

set_requirements() {
rm -rf vendor/arrow
rm -rf vendor/qcom/opensource/display
git clone --depth=1 https://github.com/passive-development/android_vendor_arrow -b arrow-13.1 vendor/arrow
git clone --depth=1 https://github.com/passive-development/android_vendor_qcom_opensource_display -b lineage-20.0 vendor/qcom/opensource/display
}

set_requirements
echo "Device requirements set successfully."
