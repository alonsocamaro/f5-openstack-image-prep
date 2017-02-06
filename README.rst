F5 OpenStack VE Image Preparation
=================================

- Used to patch and upload F5 VE images into OpenStack Glance.
- Accepts a single VE file and uploads it alone

Installation
------------
Git clone the repo directly to use this utility

Setup
-----
Refer to the requirements.txt file in the top-level directory to determine what needs to be installed.

VE Image Patching
-----------------
A VE image must be 'patched' to run in OpenStack. This allows for proper bootup of that instance with the correct intefaces and selfIPs. The patch-image.sh script in bin/ does this work. If you would like to patch a VE image in a specific way other than what is provided in the ve_image_sync.py tool, you can use the patch-image.sh script directly:

    sudo /bin/bash patch-image.sh -f -s <your_startup_script> BIGIP_11.6.qcow2

The above command patches the BIGIP_11.6.qcow2 image to be firstboot and injects a user-defined startup script before producing a patched image. The patched image will be created in $HOME/.f5-image-prep/tmp if no -o (output file) is specified. A minimal execution of the script might look like the following:

    sudo /bin/bash patch-image.sh -f BIG_11.6.qcow2

TODO: Set "guiSetup": "disabled" only if everything goes well
