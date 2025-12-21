#!/usr/bin/env python3
"""
Regenerate tree-sitter test expectations from the actual parser output.
This script reads test corpus files and regenerates the expected output.
"""

import subprocess
import sys
import re
import os

def parse_code(code):
    """Parse code using tree-sitter and return the S-expression."""
    result = subprocess.run(
        ['tree-sitter', 'parse', '/dev/stdin'],
        input=code.encode(),
        capture_output=True,
        timeout=30
    )

    output = result.stdout.decode()

    # Remove the position info [x, y] - [x, y]
    output = re.sub(r' \[\d+, \d+\] - \[\d+, \d+\]', '', output)

    # Remove warning lines and other non-tree output
    lines = []
    for l in output.split('\n'):
        if l.startswith('Warning:'):
            continue
        if l.startswith('Please run'):
            continue
        if l.startswith('configuration file'):
            continue
        if l.startswith('language grammars'):
            continue
        lines.append(l)

    return '\n'.join(lines).strip()

def parse_test_file(content):
    """Parse a test corpus file into individual tests."""
    tests = []

    # Split by the test separator pattern
    # Pattern: ==================\ntest name\n==================
    pattern = r'==================\n([^\n]+)\n=================='

    # Find all test boundaries
    matches = list(re.finditer(pattern, content))

    for i, match in enumerate(matches):
        test_name = match.group(1)
        start = match.end()

        # Find end of this test (start of next test or end of file)
        if i + 1 < len(matches):
            end = matches[i + 1].start()
        else:
            end = len(content)

        test_content = content[start:end].strip()

        # Split by ---
        parts = test_content.split('\n---\n')
        if len(parts) >= 2:
            code = parts[0].strip()
            old_expected = parts[1].strip()
            tests.append({
                'name': test_name,
                'code': code,
                'expected': old_expected,
                'match': match
            })

    return tests

def regenerate_test_file(filepath, dry_run=True):
    """Process a test corpus file and regenerate expectations."""

    with open(filepath, 'r') as f:
        content = f.read()

    tests = parse_test_file(content)

    updated = 0
    failed = 0

    new_content = ""
    last_end = 0

    matches = list(re.finditer(r'==================\n([^\n]+)\n==================', content))

    for i, test in enumerate(tests):
        match = matches[i]

        # Add content before this test
        new_content += content[last_end:match.start()]

        try:
            new_expected = parse_code(test['code'])

            if new_expected != test['expected']:
                if dry_run:
                    print(f"Would update: {test['name']}")
                else:
                    print(f"Updated: {test['name']}")
                updated += 1

            # Build the new test
            new_test = f"==================\n{test['name']}\n==================\n\n{test['code']}\n\n---\n\n{new_expected}\n"
            new_content += new_test

        except Exception as e:
            print(f"Error processing '{test['name']}': {e}")
            failed += 1
            # Keep original
            if i + 1 < len(matches):
                end = matches[i + 1].start()
            else:
                end = len(content)
            new_content += content[match.start():end]

        # Update last_end
        if i + 1 < len(matches):
            last_end = matches[i + 1].start()
        else:
            last_end = len(content)

    # Add any remaining content
    if last_end < len(content):
        remaining = content[last_end:].strip()
        if remaining:
            new_content += remaining

    print(f"\nSummary: {updated} tests would be updated, {failed} failed")

    if not dry_run and updated > 0:
        with open(filepath, 'w') as f:
            f.write(new_content)
        print(f"Written to {filepath}")

    return new_content

def main():
    if len(sys.argv) < 2:
        print("Usage: regenerate_tests.py <corpus_file> [--apply]")
        print("  --apply: Actually write changes (default is dry-run)")
        sys.exit(1)

    filepath = sys.argv[1]
    dry_run = '--apply' not in sys.argv

    if dry_run:
        print("DRY RUN - not writing changes\n")
    else:
        print("APPLYING changes\n")

    regenerate_test_file(filepath, dry_run=dry_run)

if __name__ == '__main__':
    main()
