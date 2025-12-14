FROM python:3.10

# Install PyTorch FIRST
RUN pip install --no-cache-dir torch==2.1.2+cu121 torchvision==0.16.2+cu121 torchaudio==2.1.2+cu121 --index-url https://download.pytorch.org/whl/cu121

# Copy and install requirements
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

# Install nnUNet
RUN pip install --no-cache-dir nnunetv2

# Copy all code
COPY . /app
WORKDIR /app

# Create GOUHFI-specific scripts manually
RUN echo '#!/usr/bin/env python' > /usr/local/bin/run_gouhfi && \
    echo 'import sys' >> /usr/local/bin/run_gouhfi && \
    echo 'from run_inference.gouhfi_inference_postpro_reo import main' >> /usr/local/bin/run_gouhfi && \
    echo 'if __name__ == "__main__":' >> /usr/local/bin/run_gouhfi && \
    echo '    sys.exit(main())' >> /usr/local/bin/run_gouhfi && \
    chmod +x /usr/local/bin/run_gouhfi

RUN echo '#!/usr/bin/env python' > /usr/local/bin/run_preprocessing && \
    echo 'import sys' >> /usr/local/bin/run_preprocessing && \
    echo 'from data_utils.preprocessing_pipeline import main' >> /usr/local/bin/run_preprocessing && \
    echo 'if __name__ == "__main__":' >> /usr/local/bin/run_preprocessing && \
    echo '    sys.exit(main())' >> /usr/local/bin/run_preprocessing && \
    chmod +x /usr/local/bin/run_preprocessing

RUN echo '#!/usr/bin/env python' > /usr/local/bin/run_conforming && \
    echo 'import sys' >> /usr/local/bin/run_conforming && \
    echo 'from data_utils.conform_images import main' >> /usr/local/bin/run_conforming && \
    echo 'if __name__ == "__main__":' >> /usr/local/bin/run_conforming && \
    echo '    sys.exit(main())' >> /usr/local/bin/run_conforming && \
    chmod +x /usr/local/bin/run_conforming

RUN echo '#!/usr/bin/env python' > /usr/local/bin/run_brain_extraction && \
    echo 'import sys' >> /usr/local/bin/run_brain_extraction && \
    echo 'from data_utils.brain_extraction_antspynet import main' >> /usr/local/bin/run_brain_extraction && \
    echo 'if __name__ == "__main__":' >> /usr/local/bin/run_brain_extraction && \
    echo '    sys.exit(main())' >> /usr/local/bin/run_brain_extraction && \
    chmod +x /usr/local/bin/run_brain_extraction

RUN echo '#!/usr/bin/env python' > /usr/local/bin/run_labels_reordering && \
    echo 'import sys' >> /usr/local/bin/run_labels_reordering && \
    echo 'from data_utils.reorder_labels_freesurfer_lut import main' >> /usr/local/bin/run_labels_reordering && \
    echo 'if __name__ == "__main__":' >> /usr/local/bin/run_labels_reordering && \
    echo '    sys.exit(main())' >> /usr/local/bin/run_labels_reordering && \
    chmod +x /usr/local/bin/run_labels_reordering

RUN echo '#!/usr/bin/env python' > /usr/local/bin/run_renaming && \
    echo 'import sys' >> /usr/local/bin/run_renaming && \
    echo 'from data_utils.rename_files_nnunet_convention import main' >> /usr/local/bin/run_renaming && \
    echo 'if __name__ == "__main__":' >> /usr/local/bin/run_renaming && \
    echo '    sys.exit(main())' >> /usr/local/bin/run_renaming && \
    chmod +x /usr/local/bin/run_renaming

RUN echo '#!/usr/bin/env python' > /usr/local/bin/run_add_label && \
    echo 'import sys' >> /usr/local/bin/run_add_label && \
    echo 'from data_utils.add_extra_cerebral_label import main' >> /usr/local/bin/run_add_label && \
    echo 'if __name__ == "__main__":' >> /usr/local/bin/run_add_label && \
    echo '    sys.exit(main())' >> /usr/local/bin/run_add_label && \
    chmod +x /usr/local/bin/run_add_label

RUN echo '#!/usr/bin/env python' > /usr/local/bin/run_vol_extraction && \
    echo 'import sys' >> /usr/local/bin/run_vol_extraction && \
    echo 'from data_utils.get_volume_values import main' >> /usr/local/bin/run_vol_extraction && \
    echo 'if __name__ == "__main__":' >> /usr/local/bin/run_vol_extraction && \
    echo '    sys.exit(main())' >> /usr/local/bin/run_vol_extraction && \
    chmod +x /usr/local/bin/run_vol_extraction

RUN echo '#!/usr/bin/env python' > /usr/local/bin/run_label_modif && \
    echo 'import sys' >> /usr/local/bin/run_label_modif && \
    echo 'from data_utils.remove_keep_reindex_labels import main' >> /usr/local/bin/run_label_modif && \
    echo 'if __name__ == "__main__":' >> /usr/local/bin/run_label_modif && \
    echo '    sys.exit(main())' >> /usr/local/bin/run_label_modif && \
    chmod +x /usr/local/bin/run_label_modif

# Add app to Python path so imports work
ENV PYTHONPATH="/app:${PYTHONPATH}"

# Set environment variables
ENV GOUHFI_HOME=/app
ENV nnUNet_raw=/nnUNet_raw
ENV nnUNet_preprocessed=/nnUNet_preprocessed
ENV nnUNet_results=/trained_model

# Make entrypoint executable
RUN chmod +x /app/entrypoint.sh

# Set the entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]
