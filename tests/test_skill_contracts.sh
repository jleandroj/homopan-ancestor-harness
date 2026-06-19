#!/usr/bin/env bash
# test_skill_contracts.sh -- per-skill contract validation (#11).
# For every .claude/skills/<name>/, enforce the MUST items from
# .claude/SKILL_CONTRACT.md (SKILL.md present; name==dir; description present;
# allowed-tools present, subset of the permitted set, no egress tools) and warn
# on the SHOULD items (Inputs/Outputs/Success criteria). Pure bash, no network.
# Run: bash tests/test_skill_contracts.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILLS_DIR="${PROJECT_ROOT}/.claude/skills"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; NC='\033[0m'
PASSED=0; FAILED=0; WARNED=0
pass() { echo -e "    ${GREEN}[PASS]${NC} $*"; ((PASSED++)) || true; }
fail() { echo -e "    ${RED}[FAIL]${NC} $*"; ((FAILED++)) || true; }
warn() { echo -e "    ${YELLOW}[WARN]${NC} $*"; ((WARNED++)) || true; }

# Project-permitted tools (MUST #5) and forbidden egress tools (MUST #6).
PERMITTED="Read Grep Glob Bash Write Edit NotebookEdit Task TodoWrite"
FORBIDDEN_EGRESS="WebFetch WebSearch"

# Extract a single-line frontmatter scalar value (e.g. name:, description:).
fm_value() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1; }

echo ""
echo -e "${BOLD}Skill Contract Validation${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"

if [[ ! -d "${SKILLS_DIR}" ]]; then
  echo -e "  ${YELLOW}[SKIP]${NC} no skills/ directory"; exit 0
fi

shopt -s nullglob
n_skills=0
for d in "${SKILLS_DIR}"/*/; do
  name="$(basename "${d}")"
  ((n_skills++)) || true
  echo ""; echo -e "  ${BOLD}${name}${NC}"
  SKILL="${d}SKILL.md"

  # MUST 1: SKILL.md exists
  if [[ ! -f "${SKILL}" ]]; then fail "SKILL.md missing"; continue; fi
  pass "SKILL.md present"

  # MUST 2: name == dir
  fname="$(fm_value "${SKILL}" name)"
  if [[ "${fname}" == "${name}" ]]; then pass "name matches directory"; else fail "name '${fname}' != dir '${name}'"; fi

  # MUST 3: description present
  if grep -qE '^description:' "${SKILL}"; then pass "description present"; else fail "description missing"; fi

  # MUST 4: allowed-tools present
  tools_line="$(fm_value "${SKILL}" allowed-tools)"
  if [[ -z "${tools_line}" ]]; then fail "allowed-tools missing/empty"; continue; fi
  pass "allowed-tools present"

  # Normalize the comma/space tool list.
  IFS=',' read -ra toks <<<"${tools_line}"
  unknown=""; egress=""
  for t in "${toks[@]}"; do
    t="${t// /}"; [[ -z "${t}" ]] && continue
    grep -qw "${t}" <<<"${PERMITTED}" || unknown+=" ${t}"
    grep -qw "${t}" <<<"${FORBIDDEN_EGRESS}" && egress+=" ${t}"
  done
  # MUST 5: subset of permitted
  if [[ -z "${unknown}" ]]; then pass "allowed-tools ⊆ permitted set"; else fail "non-permitted tool(s):${unknown}"; fi
  # MUST 6: no egress tools
  if [[ -z "${egress}" ]]; then pass "no egress tools"; else fail "egress tool(s) present:${egress}"; fi

  # SHOULD: I/O + success criteria
  grep -qiE '(^|[^a-z])inputs?([^a-z]|:)' "${SKILL}"      || warn "no explicit Inputs section (SHOULD)"
  grep -qiE '(^|[^a-z])outputs?([^a-z]|:)' "${SKILL}"     || warn "no explicit Outputs section (SHOULD)"
  grep -qiE 'success criteria|success:' "${SKILL}"        || warn "no explicit Success criteria (SHOULD)"
done
shopt -u nullglob

echo ""
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo -e "${BOLD}  Skills: ${n_skills} | ${PASSED} passed, ${FAILED} failed, ${WARNED} warnings${NC}"
echo -e "${BOLD}════════════════════════════════════════${NC}"
echo ""
(( FAILED == 0 )) || { echo -e "${RED}${BOLD}CONTRACT VIOLATIONS${NC}"; exit 1; }
echo -e "${GREEN}${BOLD}ALL SKILL CONTRACTS OK${NC}"; exit 0
