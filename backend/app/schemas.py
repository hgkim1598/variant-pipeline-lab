"""Request/response models.

These mirror what the existing frontend actually sends and reads. The reference
is the frontend source, not the docs:

  POST /api/uploads              front/src/features/upload/useChunkedUpload.ts
  POST /api/jobs                 front/src/pages/SubmitPage.tsx  (handleSubmit)
  GET  /api/jobs/{id}            front/src/features/job/useJobStream.ts (JobState)

Note that front/src/features/analysis-profile/types.ts declares a `SubmitRequest`
with a `files` field. SubmitPage does not use it — it posts `samples`. The wire
format below follows SubmitPage.
"""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field

# --- uploads --------------------------------------------------------------


class UploadInitRequest(BaseModel):
    filename: str
    size: int | None = None
    sampleId: str | None = None
    slotId: str | None = None


class UploadInitResponse(BaseModel):
    uploadId: str
    chunkSize: int


class UploadStatusResponse(BaseModel):
    receivedChunks: list[int]


class UploadCompleteResponse(BaseModel):
    # The frontend calls this field `path` and echoes it back in POST /api/jobs.
    # The value is an opaque token (upl_...), never a server filesystem path.
    path: str


# --- jobs -----------------------------------------------------------------


class SampleInput(BaseModel):
    sampleId: str
    # slot id -> upload token, e.g. {"r1": "upl_ab12...", "r2": "upl_cd34..."}
    files: dict[str, str]


class CreateJobRequest(BaseModel):
    profileId: str
    captureKitId: str | None = None
    options: dict[str, Any] = Field(default_factory=dict)
    samples: list[SampleInput] = Field(default_factory=list)


class CreateJobResponse(BaseModel):
    jobId: str


StepStatus = Literal["pending", "running", "completed", "warning", "failed", "skipped"]
JobStatus = Literal[
    "queued", "running", "completed", "completed_with_warnings", "failed", "cancelled"
]


class StepState(BaseModel):
    stepId: str
    status: StepStatus
    elapsedSeconds: int = 0
    messages: list[str] = Field(default_factory=list)


class JobStateResponse(BaseModel):
    jobId: str
    profileId: str
    status: JobStatus
    progress: int
    steps: list[StepState]
    logTail: list[str] = Field(default_factory=list)
    startedAt: str | None = None
    finishedAt: str | None = None
    error: str | None = None

    # Diagnostics beyond the frontend contract. The UI ignores unknown fields;
    # these exist so the pipeline's own vocabulary is never lost in translation.
    runId: str
    runMode: str
    pipelineStatus: str | None = None
    currentStep: str | None = None
    unsupportedOptions: list[str] = Field(default_factory=list)
