FROM python:3.10

# Install PyTorch FIRST
RUN pip install --no-cache-dir torch==2.1.2+cu121 torchvision==0.16.2+cu121 torchaudio==2.1.2+cu121 --index-url https://download.pytorch.org/whl/cu121

# Copy only the files needed for dependency installation (only the ones that exist)
COPY pyproject.toml ./
# Copy setup.py if it exists, otherwise skip
COPY setup.py* ./
# Copy README if it exists
COPY README.md* ./

# Install dependencies (without the full code)
RUN pip install --no-cache-dir .

# NOW copy the rest of your code
COPY . /

# Set working directory to root
WORKDIR /

# Set environment variables
ENV GOUHFI_HOME=/
ENV nnUNet_raw=/nnUNet_raw
ENV nnUNet_preprocessed=/nnUNet_preprocessed
ENV nnUNet_results=/trained_model

# Set the entrypoint
ENTRYPOINT ["/entrypoint.sh"]
