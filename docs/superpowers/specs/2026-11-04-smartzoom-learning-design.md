# SmartZoom learning from reference crops

Status: approved for implementation, including learned candidate scoring amendment.

## Intent and agreed direction

Users teach a composition profile by showing desired crops. They do not have to select parameters or understand
their names. Fit composition locally first, diagnose persistent failures, and consider semantic features only if
geometry proves insufficient. No cloud service or image upload is part of this project.
The supervised target is the complete displayed transform: horizontal position, vertical position (pan), and scale.
A well-matched zoom at the wrong position is a failed prediction. Auto fits all three jointly; Pan evaluates position
at the incoming scale using the existing overflow policy, including permitted outzoom when protection requires it.

References and learned policies have independent Detail and Overview intentions. One image/profile may have both
targets; never average them or treat one as a conflicting correction of the other. Exclusion from a reference is
context-dependent group preference, not evidence that the excluded category deserves a universally lower weight.
Include Vision face, person, attention saliency and object evidence alongside all enabled custom-detector categories.
Saliency describes visual attention, not an exact object boundary or gaze direction.

The parameter set may grow when examples justify it. Parameter count is not a product restriction; generalization,
bounded resource usage and predictable viewer behavior are restrictions. Fitting detector weights or retraining
object detection is outside this first stage: existing detections are inputs to composition.

## Approaches

- Fit existing composition rules against references: retained as a baseline and compatibility fallback, reusing
  the exact production resolver. A first-complete-group chain cannot express all reference preferences.
- Learn candidate crop scoring: approved primary direction after the user reported needing additional groups.
  Generate a bounded set from individual detected instances, spatial neighbors and existing profile groups; learn
  which displayed arrangement best matches references without requiring manual group definitions or their order.
- Ask an external semantic model to judge scenes: deferred until a specific information gap and measurable benefit
  exist. It is not a dependency or an automatic fallback.

## User workflow (proposed defaults)

1. Adjust zoom and pan, then use a viewer menu command, Save reference crop for current profile. Confirming an
   already good automatic crop uses the same command. Ordinary gestures and navigation never create examples.
2. A reference belongs to the active profile, source image and viewport geometry. Saving the same combination again
   replaces that reference; other profiles and viewport shapes remain independent. References can be removed.
3. Open Learn from references in the profile editor. Show usable, missing and excluded examples. Users can group
   related images into a series and reserve series for validation; a folder is the conservative default group.
4. Start a cancellable fit, inspect its completed candidate and compare baseline/candidate on reserved images.
   Comparison offers first better, second better, equal, both poor; assignment is balanced and hidden until voting.
5. Explicitly apply the candidate to this tab or save to this profile using existing scope rules. Retain the previous
   version for rollback. Fitting never silently changes the current viewer or persisted profile.

This is a project rather than a small editor change. Initial delivery covers single-image, unrotated Auto and Pan.
Reject spreads and unsupported rotations with an explanation. Save a manually adjusted view even if the gesture
disabled SmartZoom, provided the originating composition profile and behavior are known. Store incoming scale and
center separately from the desired final transform for Pan. Learned temporal behavior remains a later stage.

## Reference contract and private persistence

Introduce versioned value types in LoupeCore and an application-owned asynchronous reference store. Store records
in the app's private Application Support location, separate from public source and thumbnails. The builder chooses
the transactional storage format after checking StateDatabase migrations. Never include user datasets, labels,
paths, models or image copies in the repository. Do not copy originals when recording a reference.

Each record contains a stable ID; profile identity and effective profile snapshot; source bookmark/location and file
revision metadata; oriented image dimensions; viewport dimensions; normalized desired center and visible extent;
actual scale and Fit behavior; originating Auto/Pan behavior and input transform; original automatic result if
available; schema/resolver version; and a frozen snapshot of detections with detector revision identity. Store
explicit series/split membership separately from profile values. Auto and Pan references are evaluated with their
own behavior, not relabeled when a manual gesture disables SmartZoom.
Local paths in records are private runtime data, never public fixtures. Profile rename must retain reference identity;
profile deletion must offer keeping a detached dataset or deleting its references.

Capture settled displayed geometry and current detections atomically on the main actor. Do no stat, encoding or
database work there. When detections are pending, retain an immutable pending capture tied to source revision,
profile and viewport, and finish off-main only for that captured source; navigation must never attach another
image's detections. Failed/missing detections are visible states, not successful empty labels. A genuinely completed
empty detection result is a usable no-subject case. Persistence failures are reported and never shown as saved.

Capture detections for every enabled model class, with individual boxes and retained confidence scores, even for
categories outside the selected chain or final visible crop. The fitter needs scene context and competing objects,
not just the chosen target. Preserve distinct model labels as distinct categories; do not merge semantically related
labels before weighting. Record class mapping, collection floor and selection threshold so an unsearched class or
discarded low-score result is not interpreted as confirmed absence. Enabling additional classes changes analysis
identity and requires fresh detections; do not silently pad older snapshots with negative evidence. Category weights
and conditional rules may use this full evidence. Concrete user-supplied labels and their mapping stay private.

Keep exact geometry including letterboxing, because the crop/image intersection alone loses scale information for
Fit and small images. Validate finite coordinates, positive dimensions and compatibility with the production viewer.
Changed source revisions require recapture or explicit dataset migration; missing files retain numeric references
for replay but cannot supply image comparison. Detector/resolver changes do not silently rewrite frozen evidence.

## Replay, parameters and fitting

Use one pure replay evaluator shared with the production selection/composition/protection path:
effective rules -> eligible chain group -> SubjectFraming.composition -> SubjectComposition.resolve -> clamped view.
Do not implement a simplified optimizer-only crop formula. Preserve the profile's fallback behavior with no subjects.
The first-stage replay is explicitly independent-photo Auto/Pan: no carried sizes, followed-group override, guessed-head
memory or preferred previous center. Baseline and candidate comparisons both start from this same fresh context.
Store transient browsing context with capture when available for diagnosis, but do not mistake it for learned profile
values. Applying a candidate resets that profile's transient framing memory before re-framing; other profiles retain
their state. Sequence stability needs a later ordered-reference evaluator; static validation makes no claim about it.

The parameter registry covers size; chain ordering and eligible groups; weights and normalization; maxZoom; margin;
global/per-category circle radii; crop limits including explicit Off versus inheritance; global/per-category protection
margins and protection scope; panOverflow and steadyFraming. Every parameter declares domain, serialization,
dependencies and whether captured evidence can identify it. Restrict new chain combinations to valid configured
categories and bounded proposals; never enumerate their power set. Unobserved categories retain baseline settings.
Parameters irrelevant to the captured dataset (for example steadyFraming without sequences, panOverflow without Pan
references) stay unchanged with an explanation; they remain in the registry for later fitting. Gesture/navigation
settings and detector thresholds are not composition parameters and are not changed by this fitter.

Use deterministic, bounded derivative-free search because chain selection and protections are discontinuous.
Start at the effective baseline, search numeric blocks and discrete/chain neighbors with seeded restarts, retain
the best incumbent and expose cancellation/progress. No exhaustive Cartesian search. Search budgets, block sizes
and scheduler limits are selected by bench; the implementation plan must establish them before shipping.

Compare predicted and target displayed geometry using separate dimensionless viewport-relative horizontal and
vertical center displacement and logarithmic scale error. Report all three components as well as overlap of visible
image regions; aggregate robustly and weight series equally so a burst does not dominate. At equal fit prefer fewer overrides and less departure from the
baseline. Choose normalization/weights on synthetic perturbations and development data, document them, then freeze
them for final validation. This is preference fitting: learnable crop restrictions may change, but nonfinite values,
invalid domains and actual viewer geometry constraints never become soft penalties.

### Learned selection amendment

Do not make the first matching category group the only trainable selection mechanism. References supervise a local
scoring model over complete crop candidates. Candidate generation considers individual object instances (including
multiple instances of the same class), bounded spatial neighbor sets, profile groups and Fit. Avoid the full power
set. Include profile protection constraints and incoming Pan scale in the shared geometric resolver; an empty,
incompatible or unavailable learned policy falls back to the existing chain.

Features describe category-normalized displayed positions, extents, visibility and edge cuts, scene occupancy and
candidate geometry. Train from reference-versus-proposal feature differences with the geometric/object-aware
reference error as the preference margin. Freeze feature schema and model version; store learned coefficients,
baseline profile fingerprint and detector identity in private versioned policy data, never in source. Training uses
development groups only. Persist and restore policies alongside references. Each intention owns its tuned proposal
parameters internally while matching the same unchanged external baseline profile. Application is explicit per tab
or persisted baseline/detector/intent context; rollback restores the prior learned policy. Inference is local, finite and bounded,
and benchmarked alongside candidate generation. Report representational candidate coverage separately from ranking
quality: a scorer cannot choose a crop the generator never proposed. No automatic switch based only on training fit.

### Group and per-element errors

Evaluate every sample at two levels: overall group/viewport displacement and scale, and the screen-space geometry
of each detected element under the predicted and reference transforms. The user explicitly requires both levels:
a small aggregate error must not hide a badly placed individual element. Record stable instance IDs in the frozen
detection snapshot, so corresponding objects are identical evidence rather than re-matched by class between crops.

For each instance retain signed horizontal/vertical displacement in viewport units, displayed extent/scale error,
visible-area fraction, and crop fraction at each edge, comparing each measurement against the reference crop.
Use the projected full box for position, and its viewport intersection only for visibility/cut measurements; clipping
must not move the measured object center. Use one shared projection matching the actual viewer's image origin,
scale and letterboxing. Group membership used for scoring is fixed sample evidence (the captured group if known,
otherwise an explicit all-detections diagnostic group), not whatever subset the candidate chooses. Persist whether
membership was observed or inferred; it is not a claim about the user's intended subject.

Expose both total transform error and per-category/per-instance residuals. Use a normalized object-aware term in
the fitting objective alongside the global term, with fixed evaluation weights independent of candidate framing
weights; otherwise the fitter could improve its score just by ignoring an inconvenient category. Aggregate instances
within categories, then categories within each sample, and samples within series. Missing categories do not count
as successful zero-error detections. Positions outside the reference viewport remain available for diagnosis, but
must not overwhelm the loss or cause objects intentionally excluded by the reference to be pulled into view.
Measure visibility changes for excluded objects against their reference visibility rather than requiring inclusion.

With frozen detections, object positions are derived from the same pan and scale; these are correlated errors,
not independent evidence or additional ground-truth labels. The added information is object size, category and edge
visibility sensitivity. Compare the object-aware objective with the global-only baseline on development data before
freezing weights; retain the diagnostic breakdown even if it does not improve held-out framing.

For each sample show actionable observations such as an object shifted toward the left edge, a category displayed
too small, or an extra cut at the top relative to the reference. Distinguish these measured discrepancies from
unproven causes: wrong category weight, missing conditional rule and detector error remain hypotheses for review.

Use grouped development/training and validation sets. Never use validation votes or targets to choose parameters,
loss weights, restarts or search stopping. Record split and dataset revisions with each run; if validation is used to
guide a subsequent revision it becomes development data and a fresh final group is required. With too few independent
groups, allow an explicitly exploratory candidate but make no generalization claim. No automatic application based
only on training error.

## Diagnosing what cannot yet be learned

For poor examples run an optional bounded per-example fit using the same registry and evaluator. Report best found
error, not proof of a global optimum. A poor shared fit with good per-example fits suggests conflicting preferences
or missing conditional rules; poor per-example fits suggest search limits, constraints, detection gaps or missing
expressiveness. Do not label either result as mathematical impossibility. Keep difficult examples for visual review.

The initial scoring features include object count, relative geometry and scene occupancy. Viewport shape also
conditions candidate geometry; further explicit feature extensions may be evaluated later. Each new
feature/rule needs held-out benefit and versioned serialization. The app does not generate new Swift code or invent
arbitrary parameters automatically. The architecture allows additions without requiring users to tune their values.

## Ownership, cancellation and application

- Loupe owns capture commands, immutable session snapshots, profile scope, comparison presentation and run lifetime.
- LoupeCore owns reference values/store, parameter registry, deterministic replay, search and fit reports.
- DetectorProfileDraft remains the validation boundary for ordinary profiles. Learning does not rewrite detector
  configuration: tuned parameters and ranking coefficients persist together in one private atomic policy store,
  keyed by external baseline, complete detector context and intention. This also supports the built-in Vision profile.
- AppDelegate owns shared persistence; a learning coordinator owns each finite fit task. Fitting uses utility QoS,
  bounded batches and buffers, and yields while foreground loading is busy. Start with a serial worker as a benchmark
  baseline, not a claimed measured optimum. No polling at rest. Closing the learning window cancels its run.
- Dataset/profile edits invalidate results by revision. Apply checks the baseline revision and destination scope;
  stale candidates cannot overwrite newer edits. Cancellation or failed writes leave the current profile intact.
- Update docs/architecture.md with final ownership, persistence and cancellation changes in the implementation.

## Verification and acceptance

Core tests exercise reference round trips/revisions; exact replay parity with production; valid candidates and all
parameter registry fields; recovery of behavior on synthetic references without requiring unique parameter recovery;
no-subject cases; group isolation; repeatable bounded search; cancellation/stale apply; rollback and writer failures.
Viewer tests cover capture after a gesture disables SmartZoom, pending detections across navigation, profile/viewport
identity, unsupported modes, and comparison labels. Include equal-scale/different-pan references, equal-center/
different-scale references, Auto/Pan replay parity, and contextual categories outside the chosen group/crop.
Cover per-instance identity for repeated same-class detections, projected centers versus clipped centers,
opposing object displacements hidden by group averages, equal category weighting with many instances, intentionally
excluded objects, candidate-independent loss weights and viewport-edge/letterboxing geometry.
Generic synthetic objects only.

Run scripts/test.sh; render/full suites follow docs/testing.md if transform/render behavior changes. Bench the real
capture and learning window on Intel: control actions <=50 ms main-thread CPU, opening <=300 ms; include first/return
and repeated rounds. Record foreground navigation latency, peak memory, worker load and cancellation latency while
fitting. Document actual machines, dataset sizes, measured search budgets and before/after in docs/bench.

Acceptance requires usable references across restart, fitting without manual parameter selection, reversible explicit
application, honest reporting of unresolved examples, and no perceptible foreground regression. A quality improvement
claim requires separate held-out user comparisons; implementation tests alone cannot establish personal taste.

## Decisions left to the builder

Future mouse actions: toggle Auto framing and toggle Detail/Overview, retaining the selected intention while Auto is
off. These replace group-next/group-previous conceptually; actual mouse bindings are outside this implementation.

Choose concrete storage schema/migrations, menu placement without shortcut conflicts, native comparison layout,
optimizer implementation, and measured numeric budgets. Keep the existing renderer and configuration layering.
Review these choices in the implementation plan; they do not require another product questionnaire.

## Implemented first-stage limits

Capture requires a decoded, settled, oriented single-image filesystem view; archive entries and
spreads are rejected explicitly. Mounted-volume latency has not been benchmarked. Comparison votes are immutable evaluation evidence, not additional training targets
in this first stage. Candidate generation reserves a bounded share for configured groups (32 at the default budget),
then individual instances and spatial combinations. It does not enumerate arbitrary power sets. Synthetic benches
validate bounded work and responsiveness; taste quality and Intel timings still require real user data and hardware.
