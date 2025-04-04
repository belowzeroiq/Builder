#!/bin/bash

set_requirements() {
rm -rf vendor/arrow
git clone --depth=1 https://github.com/passive-development/android_vendor_arrow -b arrow-13.1 vendor/arrow
}

set_requirements
echo "Device requirements set successfully."
