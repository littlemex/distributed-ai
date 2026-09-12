# DFlash2 is not in a published SGLang image, so bake the sglang python (from a pinned upstream
# commit) on top of the pinned nightly base at BUILD time (not at pod start). The base ships the
# prebuilt sgl-kernel / CUDA / torch, so only the python package (incl. its Rust server) is built here.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG SGLANG_COMMIT
RUN pip install -U --no-deps "sglang @ git+https://github.com/sgl-project/sglang.git@${SGLANG_COMMIT}#subdirectory=python" \
 && python3 -c "from sglang.srt.models.dflash import DFlash2DraftModel; print('DFlash2DraftModel OK')"
LABEL org.opencontainers.image.revision="${SGLANG_COMMIT}"
