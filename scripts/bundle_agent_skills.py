"""Bundle installed, portable agent skills and their references without copying user config."""

import argparse
import io
import json
import re
import tarfile
from pathlib import Path


# The names advertised to this assistant, not every unrelated skill installed on the Mac.
NAMES = set("""
3d-web-experience ai-sdk-5 android-design-guidelines angular-architecture angular-core
angular-forms angular-performance animation-router anime-js apple-appstore-reviewer
backend-router branch-pr brandkit caveman chained-pr cognitive-doc-design comment-writer
conventional-commit cybersecurity-router design-taste-frontend design-taste-frontend-v1
devops-router django-drf django-expert docker-containerization docker-expert electron
elixir-antipatterns expo-ui figma-use flutter-apply-architecture-best-practices frontend-design
frontend-router full-output-enforcement gentle-ai-bench gentleman-guardian-angel github-pr
go-testing google-analytics gpt-taste gsap-core gsap-frameworks gsap-performance gsap-plugins
gsap-react gsap-scrolltrigger gsap-timeline gsap-utils hexagonal-architecture-layers-java
high-end-visual-design i-have-adhd image-to-code imagegen-frontend-mobile imagegen-frontend-web
industrial-brutalist-ui ios-design-guidelines ipados-design-guidelines issue-creation java-21
jira-epic jira-task judgment-day macos-design-guidelines minimalist-ui mobile-router
network-security-router nextjs-15 platform-router playwright ponytail ponytail-audit
ponytail-debt ponytail-gain ponytail-help ponytail-review pr-review protocol-reverse-engineering
pytest rag-implementation rdd-defect-workflow react-19 react-native redesign-existing-projects
sdd-apply sdd-archive sdd-design sdd-explore sdd-init sdd-onboard sdd-propose sdd-spec sdd-tasks
sdd-verify skill-creator skill-improver skill-registry solidity-security spring-boot-3
ssl-tls-management stitch-design-taste supabase-postgres-best-practices swiftdata-pro
swiftui-expert-skill swiftui-pro system-prompts-leaks systemic-issue-triage tailwind-4
telegram-bot tvos-design-guidelines typescript universal-ui vercel-react-best-practices vgpu
visionos-design-guidelines watchos-design-guidelines web-design-guidelines work-unit-commits
zod-4 zustand-5
""".split())

EXCLUDED = {".git", ".env", ".venv", "node_modules", "__pycache__", ".pytest_cache"}


def add_package(archive, source, destination, *, support=False):
    count = 0
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        if any(part.startswith(".") or part in EXCLUDED for part in relative.parts):
            continue
        if not path.is_file() or path.is_symlink():
            continue
        if path.name == "SKILL.md" and (support or len(relative.parts) > 1):
            continue
        if path.suffix.lower() in {".pem", ".key", ".p12", ".db", ".sqlite3", ".pyc"}:
            continue
        archive.add(path, arcname=str(destination / relative), recursive=False)
        count += 1
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    home = Path.home()
    roots = [home / ".agents/skills", home / ".config/opencode/skills",
             home / ".config/opencode/skill", home / ".claude/skills"]
    selected = {}
    for root in roots:
        for path in sorted(root.glob("**/SKILL.md")):
            text = path.read_text(encoding="utf-8")
            match = re.search(r"^name:\s*['\"]?([a-z0-9-]+)['\"]?\s*$", text, re.M)
            if match and match[1] in NAMES and match[1] not in selected:
                selected[match[1]] = path.resolve().parent
    missing = NAMES - selected.keys()
    if missing:
        raise SystemExit("Missing skill packages: " + ", ".join(sorted(missing)))
    files = 0
    with tarfile.open(args.output, "w:gz") as archive:
        for name, source in sorted(selected.items()):
            files += add_package(archive, source, Path(".opencode/skills") / name)
        # SDD packages refer to ../_shared; these are support docs, not callable skills.
        files += add_package(archive, home / ".agents/skills/_shared",
                             Path(".opencode/skills/_shared"), support=True)
        manifest = json.dumps({"skills": sorted(selected), "files": files,
                               "excluded_builtin": ["customize-opencode"]}, indent=2).encode()
        info = tarfile.TarInfo(".opencode/skills/installed-manifest.json")
        info.size = len(manifest)
        info.mode = 0o644
        archive.addfile(info, io.BytesIO(manifest))
    print(f"Bundled {len(selected)} skills and {files} files ({args.output.stat().st_size} bytes).")
    print("Built-in customize-opencode has no portable source file; not bundled.")


if __name__ == "__main__":
    main()
