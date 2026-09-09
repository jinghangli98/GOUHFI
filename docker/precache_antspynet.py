"""Pre-download the ANTsPyNet brain-extraction weights (t1 and t2) at image build time.

Running a real brain extraction on a bundled sample image fetches exactly the files the
runtime needs (network weights + registration template) into KERAS_HOME, so the container
can run offline afterwards.
"""
import os

import ants
import antspynet

image = ants.image_read(antspynet.get_antsxnet_data("mprage_hippmapp3r"))
for modality in ("t1", "t2"):
    print(f"--- caching ANTsPyNet brain-extraction weights for modality={modality}", flush=True)
    antspynet.brain_extraction(image, modality=modality, verbose=True)

cache = os.environ.get("KERAS_HOME", os.path.expanduser("~/.keras"))
print(f"ANTsPyNet weights cached in {cache}:")
for root, _, files in os.walk(cache):
    for f in files:
        p = os.path.join(root, f)
        print(f"  {p}  ({os.path.getsize(p) / 1e6:.1f} MB)")
