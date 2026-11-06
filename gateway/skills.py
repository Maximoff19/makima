"""Skill loading.

A skill is a markdown file with YAML frontmatter (name, description). Skills are matched
against the current question by keyword overlap on name+description, and only the ones
that match are injected into the system prompt. This is the same discipline as memory
retrieval, for the same reason: injecting everything is what pollutes the context.

The gateway already has web search wired as a tool, so this mirrors that shape: the model
is told which skills apply instead of being handed the whole library.
"""

import logging
import os
import re
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

logger = logging.getLogger("makima.skills")

SKILLS_DIR = Path(os.getenv("MAKIMA_SKILLS_DIR", str(Path(__file__).parent / "skills")))

# Same stopword policy as memory retrieval: a shared function word is not a match.
_STOPWORDS = {
    "que", "qué", "como", "cómo", "para", "donde", "dónde", "cuando", "cuándo",
    "este", "esta", "esto", "es", "son", "del", "los", "las", "una", "uno", "con",
    "por", "sin", "sobre", "entre", "pero", "muy", "mas", "más", "the", "and",
    "with", "for", "this", "that", "you", "your", "how", "what", "when", "where",
    "why", "can", "about", "from", "into", "todo", "todos", "toda", "cuanto",
}


@dataclass(frozen=True)
class Skill:
    name: str
    description: str
    body: str

    @property
    def haystack(self) -> str:
        return f"{self.name} {self.description}".lower()


def _parse(text: str) -> Skill | None:
    if not text.startswith("---"):
        return None
    end = text.find("\n---", 3)
    if end == -1:
        return None
    front = text[3:end]
    body = text[end + 4:].strip()
    name = description = ""
    for line in front.splitlines():
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip().lower()
        if key == "name":
            name = value.strip()
        elif key == "description":
            description = value.strip()
    if not name or not body:
        return None
    return Skill(name=name, description=description, body=body)


@lru_cache(maxsize=1)
def _load() -> tuple[Skill, ...]:
    if not SKILLS_DIR.is_dir():
        return ()
    skills: list[Skill] = []
    for path in sorted(SKILLS_DIR.glob("*.md")):
        try:
            skill = _parse(path.read_text(encoding="utf-8"))
        except OSError as exc:
            logger.error("Could not read skill %s: %s", path.name, exc)
            continue
        if skill:
            skills.append(skill)
    logger.info("Loaded %d skills from %s", len(skills), SKILLS_DIR)
    return tuple(skills)


def reload() -> None:
    _load.cache_clear()


def _normalise(word: str) -> str:
    """Collapse the plurals that matter for matching without a real stemmer.

    A full stemmer would need nltk and would also fold words that share morphology but
    not meaning. Stripping a trailing plural 's' is enough to make "recuerdo" match
    "recuerdos", which is the case that actually came up.
    """
    if len(word) > 4 and word.endswith("s") and not word.endswith("ss"):
        return word[:-1]
    return word


def terms(text: str) -> set[str]:
    # 3 characters is the floor: VPS, CPU and RAM are all three and none of them are
    # stopwords, so a 4-char minimum threw away exactly the operational vocabulary.
    words = re.findall(r"[^\W_]+", text.lower())
    return {_normalise(w) for w in words if len(w) >= 3 and w not in _STOPWORDS}


def select(question: str, limit: int = 2, min_shared: int = 1) -> list[Skill]:
    """Skills whose name/description genuinely overlap the question."""
    wanted = terms(question)
    if not wanted:
        return []
    scored: list[tuple[int, str, Skill]] = []
    for skill in _load():
        shared = wanted & terms(skill.haystack)
        if len(shared) >= min_shared:
            scored.append((len(shared), skill.name, skill))
    scored.sort(key=lambda item: (-item[0], item[1]))
    return [skill for _, _, skill in scored[:limit]]


def render(question: str, limit: int = 2) -> str:
    picked = select(question, limit=limit)
    if not picked:
        return ""
    blocks = [f"## Skill: {s.name}\n{s.body}" for s in picked]
    return "\n\n".join(blocks) + (
        "\n\nUsa estas skills solo si la peticion actual lo pide. "
        "No las menciones ni las recites."
    )
