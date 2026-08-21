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


# --- results --------------------------------------------------------------
#
# Appended for GET /api/jobs/{id}/results and the artifact endpoints. Nothing
# above this line changes: the models below are additive, and the existing
# job/upload contract is untouched.
#
# Every field here is derived from a document main.sh wrote. Optional fields
# are optional because the pipeline genuinely may not have recorded them yet --
# a precheck that failed on required_tools never got as far as capturing the
# reference metadata. None means "the pipeline did not report this", never "the
# backend could not be bothered to look".


ResultType = Literal["precheck", "full"]

# Vocabulary for an optional step's outcome. `unsupported` and `unavailable`
# are reserved for the case where the option was requested but the server
# cannot honour it; deciding that requires inspecting the InterVar
# configuration, which is deliberately not part of this iteration.
OptionalStepState = Literal[
    "not_run",
    "unsupported",
    "failed",
    "completed",
    "file_missing",
    "unavailable",
]


class CheckResult(BaseModel):
    """One row of a step's named check table (validation.results)."""

    name: str
    # main.sh writes PASS / WARN / FAIL uppercase.
    status: str
    detail: str = ""


class PipelineWarning(BaseModel):
    stepId: str | None = None
    code: str = ""
    message: str
    impact: str = ""
    canContinue: bool = False


class PipelineFailure(BaseModel):
    stepId: str | None = None
    code: str = ""
    message: str


class InputSummary(BaseModel):
    """Resource metadata captured by 00_input_validation.

    Checksums are the ones the run declared and verified; they are metadata,
    not paths, so they are safe to return.
    """

    sample: str | None = None
    laneCount: int | None = None
    assembly: str | None = None
    contigStyle: str | None = None
    bundleId: str | None = None
    captureKitId: str | None = None
    captureKitMode: str | None = None
    targetBedSha256: str | None = None
    coverageBedSha256: str | None = None


class CoverageSummary(BaseModel):
    """mosdepth-derived numbers, passed through exactly as main.sh wrote them."""

    meanTargetDepth: float | None = None
    targetNonoverlapBases: int | None = None
    # Depth label -> percent of target bases at or above it, e.g. {"20X": 94.2}.
    # Keys follow the mosdepth --thresholds list, so they are read from the
    # document rather than assumed.
    breadth: dict[str, float] = Field(default_factory=dict)
    lowCoverageBasesPct: float | None = None
    lowCoverageThresholdX: float | None = None
    lowCoverageBases: int | None = None
    lowCoverageIntervals: int | None = None
    uncoveredBasesPct: float | None = None
    uncoveredBases: int | None = None
    uncoveredIntervals: int | None = None
    # Always null: mosdepth runs with --no-per-base, so a per-base median was
    # never materialised. medianNote carries the pipeline's own explanation.
    # Never synthesise a value here.
    medianTargetDepth: None = None
    medianNote: str | None = None


class VariantCallingSummary(BaseModel):
    """Core variant-calling result.

    Only the run-relative VCF paths appear. variant_calling_output.json also
    carries absolute server paths (`raw_vcf`, `gvcf`); those are never read into
    a response.
    """

    sample: str | None = None
    assembly: str | None = None
    rawVariantRecords: int | None = None
    filteringApplied: bool = False
    coreEndpoint: str = "raw VCF (no filtering applied)"
    rawVcfRelative: str | None = None
    gvcfRelative: str | None = None


class JobResultsResponse(BaseModel):
    jobId: str
    runId: str
    resultType: ResultType
    # False for every --check-only run: no analysis tool was executed.
    analysisOutputProduced: bool
    # Reconciled the same way GET /api/jobs/{id} reconciles it, so the two
    # endpoints can never disagree about a job.
    status: JobStatus
    pipelineStatus: str | None = None
    schemaVersion: str | None = None
    sample: str | None = None
    elapsedSeconds: int | None = None

    checks: list[CheckResult] = Field(default_factory=list)
    warnings: list[PipelineWarning] = Field(default_factory=list)
    failures: list[PipelineFailure] = Field(default_factory=list)

    inputSummary: InputSummary | None = None
    coverage: CoverageSummary | None = None
    variantCalling: VariantCallingSummary | None = None

    optionalSteps: dict[str, OptionalStepState] = Field(default_factory=dict)
    # Result view ids the frontend registry can actually render for this run.
    # Only views whose data exists are listed.
    availableViews: list[str] = Field(default_factory=list)
    artifactCount: int = 0
    intendedUse: str | None = None


class ArtifactEntry(BaseModel):
    fileId: str
    stepId: str = ""
    kind: str = ""
    displayName: str = ""
    # Always relative to the run directory. An absolute server path never
    # appears in an API response.
    relativePath: str
    sizeBytes: int | None = None
    sha256: str | None = None
    downloadable: bool = False
    description: str = ""
    # Whether the file is still on disk. A registered artifact can legitimately
    # be gone; that is reported rather than hidden.
    available: bool = True


class ArtifactListResponse(BaseModel):
    jobId: str
    artifactCount: int
    # artifact_manifest.json is a cross-check only, never the source of truth:
    # main.sh writes it before the finalization step publishes its own
    # artifacts, so it is structurally short by however many that step
    # registered. manifestConsistent false is expected on a full run.
    manifestPresent: bool = False
    manifestConsistent: bool = False
    # Entries dropped because they were malformed or pointed outside the run
    # directory. Reported rather than silently omitted.
    suppressedCount: int = 0
    artifacts: list[ArtifactEntry] = Field(default_factory=list)
