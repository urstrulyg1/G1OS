import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Activity, Check, CircleAlert, Clock3, Loader2, RefreshCw } from "lucide-react";

type Step = {
  name: string;
  status: string;
  conclusion: string | null;
};

type Job = {
  name: string;
  status: string;
  conclusion: string | null;
  steps?: Step[];
};

type Run = {
  id: number;
  status: string;
  conclusion: string | null;
  created_at: string;
  updated_at: string;
  head_branch: string | null;
  html_url: string;
};

type Snapshot = {
  run: Run;
  jobs: Job[];
  observedAt: number;
};

const API = "https://api.github.com";
const RUNS_URL = `${API}/repos/urstrulyg1/G1OS/actions/workflows/g1os-build.yml/runs?branch=main&per_page=10`;
const ACTIVE_POLL_MS = 5000;
const IDLE_POLL_MS = 30000;
const STALE_AFTER_MS = 15000;

function statusLabel(status: string, conclusion: string | null) {
  if (status === "completed") {
    if (conclusion === "success") return "Completed successfully";
    if (conclusion === "cancelled") return "Cancelled";
    return `Failed${conclusion ? ` (${conclusion})` : ""}`;
  }
  if (status === "queued") return "Queued";
  if (status === "in_progress") return "In progress";
  return status.replace(/_/g, " ");
}

export function BuildProgress() {
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [now, setNow] = useState(() => Date.now());
  const runEtag = useRef<string | null>(null);
  const jobsEtag = useRef<string | null>(null);
  const knownRunId = useRef<number | null>(null);
  const timer = useRef<number | null>(null);

  const fetchJson = useCallback(async <T,>(url: string, etagRef: React.MutableRefObject<string | null>) => {
    const headers: Record<string, string> = { Accept: "application/vnd.github+json" };
    if (etagRef.current) headers["If-None-Match"] = etagRef.current;

    const response = await fetch(url, { headers, cache: "no-store" });
    if (response.status === 304) return null;
    if (!response.ok) throw new Error(`GitHub API returned ${response.status}`);

    const etag = response.headers.get("ETag");
    if (etag) etagRef.current = etag;
    return (await response.json()) as T;
  }, []);

  const fetchRunAndJobs = useCallback(async () => {
    try {
      const runs = await fetchJson<{ workflow_runs: Run[] }>(RUNS_URL, runEtag);
      const candidates = runs?.workflow_runs ?? (snapshot?.run ? [snapshot.run] : []);
      const active = candidates.find((run) => run.status === "in_progress" || run.status === "queued");
      const run = active ?? candidates[0];

      if (!run) {
        setSnapshot(null);
        setError(null);
        return false;
      }

      if (knownRunId.current !== run.id) {
        knownRunId.current = run.id;
        jobsEtag.current = null;
      }

      const jobs = await fetchJson<{ jobs: Job[] }>(
        `${API}/repos/urstrulyg1/G1OS/actions/runs/${run.id}/jobs?per_page=100`,
        jobsEtag,
      );

      if (jobs) {
        setSnapshot({ run, jobs: jobs.jobs, observedAt: Date.now() });
      } else if (snapshot && snapshot.run.id === run.id) {
        setSnapshot((current) => current ? { ...current, observedAt: Date.now() } : current);
      }
      setError(null);
      return run.status !== "completed";
    } catch (err) {
      setError(err instanceof Error ? err.message : "Unable to read build status");
      return Boolean(snapshot && snapshot.run.status !== "completed");
    }
  }, [fetchJson, snapshot]);

  useEffect(() => {
    let cancelled = false;

    const poll = async () => {
      if (cancelled) return;
      const active = await fetchRunAndJobs();
      if (cancelled) return;
      setNow(Date.now());
      timer.current = window.setTimeout(poll, active ? ACTIVE_POLL_MS : IDLE_POLL_MS);
    };

    void poll();
    const clock = window.setInterval(() => setNow(Date.now()), 1000);

    return () => {
      cancelled = true;
      if (timer.current) window.clearTimeout(timer.current);
      window.clearInterval(clock);
    };
  }, [fetchRunAndJobs]);

  const progress = useMemo(() => {
    if (!snapshot) return null;

    const steps = snapshot.jobs.flatMap((job) => job.steps ?? []);
    const total = steps.length;
    const completed = steps.filter((step) => step.status === "completed").length;
    const failed = steps.some((step) => step.status === "completed" && step.conclusion !== "success");
    const activeStep = steps.find((step) => step.status === "in_progress");
    const pendingStep = steps.find((step) => step.status !== "completed");
    const lastCompleted = [...steps].reverse().find((step) => step.status === "completed");
    const runFinished = snapshot.run.status === "completed";
    const successful = runFinished && snapshot.run.conclusion === "success";

    // Never manufacture progress: the percentage is derived only from observed GitHub Actions steps.
    const percent = total > 0 ? Math.min(99, Math.floor((completed / total) * 100)) : 0;
    const verifiedPercent = successful ? 100 : percent;
    const currentStep = activeStep?.name ?? pendingStep?.name ?? lastCompleted?.name ?? "Waiting for build steps";

    return {
      percent: verifiedPercent,
      currentStep,
      failed: failed || (runFinished && snapshot.run.conclusion !== "success"),
      active: !runFinished,
      successful,
      total,
      completed,
    };
  }, [snapshot]);

  if (!snapshot) {
    return (
      <div className="rounded-2xl border border-line bg-ink-2 p-6">
        <div className="flex items-center gap-3">
          <Clock3 size={17} className="text-white/45" />
          <div>
            <h3 className="text-[15px] font-semibold text-white">Live build progress</h3>
            <p className="mt-1 text-[12px] text-white/40">No G1OS build run is currently available.</p>
          </div>
        </div>
      </div>
    );
  }

  const stale = now - snapshot.observedAt > STALE_AFTER_MS;
  const displayStatus = error ? "Status unavailable — holding last verified state" : statusLabel(snapshot.run.status, snapshot.run.conclusion);

  return (
    <div className="rounded-2xl border border-line bg-ink-2 p-6" aria-live="polite">
      <div className="flex items-start gap-3">
        <div className="mt-0.5 grid h-8 w-8 place-items-center rounded-full bg-white/[0.06]">
          {progress?.active ? <Activity size={16} className="text-emerald-300" /> : progress?.successful ? <Check size={16} className="text-emerald-300" /> : <CircleAlert size={16} className="text-amber-300" />}
        </div>
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
            <h3 className="text-[15px] font-semibold text-white">Live build progress</h3>
            <span className="font-mono text-[10.5px] text-white/35">run #{snapshot.run.id}</span>
            {progress?.active && <span className="inline-flex items-center gap-1 rounded-full bg-emerald-400/10 px-2.5 py-1 text-[10px] text-emerald-300"><Loader2 size={10} className="animate-spin" /> updating every 5s</span>}
          </div>
          <p className="mt-1 text-[12px] text-white/45">{displayStatus}</p>
        </div>
        <a href={snapshot.run.html_url} target="_blank" rel="noreferrer" className="rounded-md p-1.5 text-white/35 transition-colors hover:bg-white/[0.06] hover:text-white" aria-label="Open GitHub Actions run">
          <RefreshCw size={14} />
        </a>
      </div>

      <div className="mt-5">
        <div className="mb-2 flex items-center justify-between gap-3 text-[11px]">
          <span className="truncate text-white/60">{progress?.currentStep}</span>
          <span className="font-mono font-semibold text-white">{progress?.percent ?? 0}%</span>
        </div>
        <div className="h-2 overflow-hidden rounded-full bg-white/[0.07]" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={progress?.percent ?? 0}>
          <div className="h-full rounded-full bg-emerald-400 transition-[width] duration-500" style={{ width: `${progress?.percent ?? 0}%` }} />
        </div>
        <div className="mt-2 flex justify-between text-[10px] text-white/30">
          <span>{progress?.completed ?? 0} / {progress?.total ?? 0} observed steps</span>
          <span>{stale ? "Waiting for a fresh observation…" : `Updated ${Math.max(0, Math.floor((now - snapshot.observedAt) / 1000))}s ago`}</span>
        </div>
      </div>

      {error && (
        <p className="mt-4 rounded-lg bg-amber-400/10 px-3 py-2 text-[11px] leading-relaxed text-amber-200">
          {error}. Progress will not advance until a fresh GitHub Actions observation is received.
        </p>
      )}
    </div>
  );
}
