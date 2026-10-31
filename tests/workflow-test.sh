#!/bin/bash
# Shellchecks every run: block of the workflows under the shell that runs it:
# container jobs default to sh, so bash syntax needs "shell: bash".
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work" .github/workflows/*.yml <<'PY'
import re, sys, yaml
out = sys.argv[1]
n = 0
for path in sys.argv[2:]:
    wf = yaml.safe_load(open(path))
    wf_shell = ((wf.get("defaults") or {}).get("run") or {}).get("shell")
    for job_name, job in wf["jobs"].items():
        job_shell = ((job.get("defaults") or {}).get("run") or {}).get("shell")
        default = "sh" if job.get("container") else "bash"
        for i, step in enumerate(job.get("steps", [])):
            if "run" not in step:
                continue
            shell = (step.get("shell") or job_shell or wf_shell or default).split()[0]
            body = re.sub(r"\$\{\{[^}]*\}\}", "EXPR", step["run"])
            n += 1
            name = f"{path.split('/')[-1]}.{job_name}.{i}.{shell}"
            with open(f"{out}/{name}", "w") as f:
                f.write(f"#!/bin/{shell}\n{body}")
print(f"{n} run blocks", file=sys.stderr)
PY
status=0
for f in "$work"/*; do
    if shellcheck -S warning "$f" > "$work.log" 2>&1; then
        echo "ok ${f##*/}"
    else
        echo "FAIL ${f##*/}"; cat "$work.log"; status=1
    fi
done
rm -f "$work.log"
exit "$status"
