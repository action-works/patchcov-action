"""Static fixture contracts for integration.yml and pr-paths.yml (#15).

This is a reader for the current block layout, not a YAML or shell interpreter.
Only unconditional, standalone commands count. Unsupported job/step layout raises
an error rather than silently returning no actions. No third-party dependencies.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def scalar(value):
    return value.strip().strip("\"'")


def jobs(text):
    result = {}
    job = None
    step = None
    in_jobs = False
    run_indent = None
    in_steps = False
    for number, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        if not line.startswith(' '):
            in_jobs = line == 'jobs:'
            job = step = None
            run_indent = None
            continue
        if not in_jobs:
            continue
        indent = len(line) - len(line.lstrip())
        if indent == 2:
            match = re.fullmatch(r'  ([\w-]+|"[\w-]+"|\'[\w-]+\'):', line)
            if not match:
                raise ValueError(f'unsupported job layout at line {number}')
            job = scalar(match[1])
            if job in result:
                raise ValueError(f'duplicate job {job}')
            result[job] = []
            step = None
            run_indent = None
            in_steps = False
        elif indent == 4:
            in_steps = line.strip() == 'steps:'
            step = None
        elif in_steps and indent == 6 and line.lstrip().startswith('- '):
            step = {'line': number, 'commands': []}
            result[job].append(step)
            run_indent = None
            field = line.strip()[2:]
            if field.startswith('{'):
                raise ValueError(f'unsupported flow step at line {number}')
            if ':' not in field:
                raise ValueError(f'unsupported step at line {number}')
            key, value = field.split(':', 1)
            step[key] = scalar(value.split(' #', 1)[0])
            if key == 'run':
                if value.strip() in ('|', '|-', '|+'):
                    run_indent = 10
                else:
                    step['commands'].append(value.strip())
        elif in_steps and indent == 6:
            raise ValueError(f'unsupported step layout at line {number}')
        elif step is not None:
            if run_indent and indent >= run_indent:
                # Commands nested under if/loops are not unconditional evidence.
                if indent == run_indent or (step['commands'] and step['commands'][-1].endswith('\\')):
                    step['commands'].append(line.strip().split(' #', 1)[0])
                continue
            run_indent = None
            if indent in (8, 10):
                key, sep, value = line.strip().partition(':')
                if not sep:
                    raise ValueError(f'unsupported field at line {number}')
                if key == 'run':
                    if value.strip() in ('|', '|-', '|+'):
                        run_indent = 10
                    elif value.strip().startswith(('>', '|')):
                        raise ValueError(f'unsupported run block at line {number}')
                    else:
                        step['commands'].append(value.strip())
                # Only step-level keys and with.run-coverage are needed.
                if indent == 8 or key == 'run-coverage':
                    step[key] = scalar(value.split(' #', 1)[0])
    return result


def commands(step):
    return '\n'.join(step['commands']).replace('\\\n', ' ')


def call(step, script, argument=''):
    pattern = rf'(?:bash|sh) (?:\./)?tests/{re.escape(script)}'
    if argument:
        pattern += ' ' + argument
    return any(re.fullmatch(pattern, line) for line in step['commands'])


def history(step):
    script = commands(step)
    # The base must contain all report paths; the second commit creates the delta.
    patterns = [
        r'^git add Cargo\.toml src/lib\.rs src/ignored\.rs$',
        r"^git -c user.name=integration-test -c user.email=integration-test@invalid\s+commit -q -m 'test: add the delta crate \(base\)'$",
        r'^cp tests/fixtures/delta-crate/lib\.head\.rs src/lib\.rs$',
        r"^git -c user.name=integration-test -c user.email=integration-test@invalid\s+commit -q -am 'test: change the delta crate \(head\)'$",
    ]
    positions = [re.search(p, script, re.M) for p in patterns]
    return all(positions) and [p.start() for p in positions] == sorted(p.start() for p in positions)


def check(text, kind):
    checked = []
    errors = []
    for job, steps in jobs(text).items():
        checkout = -1
        for index, step in enumerate(steps):
            if step.get('uses', '').startswith('actions/checkout@'):
                checkout = index
            if step.get('uses') != './':
                continue
            action = step.get('id', f'line {step["line"]}')
            checked.append((job, action))
            requirements = []
            if kind == 'integration':
                if step.get('run-coverage') != 'false':
                    requirements = [('fat crate', lambda s: call(s, 'prepare-fat-crate.sh'))]
            elif job == 'publish' and action == 'b1':
                requirements = [('baseline', lambda s: call(s, 'write-pr-fixtures.sh', 'baseline'))]
            elif job == 'pull-request' and action in {f'p{i}' for i in range(1, 11)}:
                requirements = [('head', lambda s: call(s, 'write-pr-fixtures.sh', 'head'))]
                if action in ('p5', 'p6', 'p10'):
                    requirements.append(('extra', lambda s: call(s, 'write-pr-fixtures.sh', 'extra')))
            elif job == 'recompute' and action in ('r1', 'r2', 'r3'):
                requirements = [('base/head history', history)]
            else:
                errors.append(f'{job}/{action}: unclassified PR fixture scenario')
                continue
            for label, predicate in requirements:
                if checkout < 0 or 'if' in steps[checkout] or not any(
                    'if' not in s and 'working-directory' not in s and predicate(s)
                    for s in steps[checkout + 1:index]
                ):
                    errors.append(f'{job}/{action}: missing unconditional {label} preparation after checkout and before action')
    return checked, errors


class WiringTests(unittest.TestCase):
    def setUp(self):
        self.integration = (ROOT / '.github/workflows/integration.yml').read_text()
        self.pr = (ROOT / '.github/workflows/pr-paths.yml').read_text()

    def test_real_workflows(self):
        actions, errors = check(self.integration, 'integration')
        self.assertEqual(errors, [])
        self.assertEqual(len(actions), 25)
        self.assertEqual(sum(job == 'fat-mode' for job, _ in actions), 6)
        actions, errors = check(self.pr, 'pr')
        self.assertEqual(errors, [])
        self.assertEqual(len(actions), 14)
        self.assertEqual({job for job, _ in actions}, {'publish', 'pull-request', 'recompute'})

    def assert_mutation(self, text, old, new, kind, expected):
        self.assertIn(old, text)
        changed = text.replace(old, new, 1)
        _, errors = check(changed, kind)
        self.assertTrue(any(expected in error for error in errors), errors)

    def test_setup_mutations(self):
        for text, kind, command, expected in [
            (self.integration, 'integration', 'bash tests/prepare-fat-crate.sh', 'fat-mode/f1'),
            (self.pr, 'pr', 'bash tests/write-pr-fixtures.sh baseline', 'publish/b1'),
            (self.pr, 'pr', 'bash tests/write-pr-fixtures.sh head', 'pull-request/p2'),
            (self.pr, 'pr', 'bash tests/write-pr-fixtures.sh extra', 'pull-request/p5'),
        ]:
            for replacement in ('true', '# ' + command, 'echo "' + command + '"', 'true # ' + command):
                with self.subTest(command=command, replacement=replacement):
                    self.assert_mutation(text, command, replacement, kind, expected)

    def test_late_and_conditional_real_preparation(self):
        for text, kind, job, command in [
            (self.integration, 'integration', 'fat-mode', 'bash tests/prepare-fat-crate.sh'),
            (self.pr, 'pr', 'publish', 'bash tests/write-pr-fixtures.sh baseline'),
            (self.pr, 'pr', 'pull-request', 'bash tests/write-pr-fixtures.sh head'),
            (self.pr, 'pr', 'pull-request', 'bash tests/write-pr-fixtures.sh extra'),
        ]:
            for mode in ('late', 'conditional', 'before-checkout'):
                with self.subTest(job=job, command=command, mode=mode):
                    prefix, block = text.split(f'  {job}:', 1)
                    match = re.search(r'\n  [\w-]+:', block)
                    end = match.start() if match else len(block)
                    body, suffix = block[:end], block[end:]
                    body = body.replace(command, 'true', 1)
                    setup = f'      - run: {command}\n'
                    if mode == 'late':
                        body += '\n' + setup
                    else:
                        point = body.index('      - uses: actions/checkout@')
                        if mode == 'conditional':
                            point = body.index('\n      - ', point + 1) + 1
                            setup += '        if: false\n'
                        body = body[:point] + setup + body[point:]
                    _, errors = check(prefix + f'  {job}:' + body + suffix, kind)
                    self.assertTrue(any(e.startswith(job + '/') for e in errors), errors)

    def test_history_mutations(self):
        for command in ('git add Cargo.toml src/lib.rs src/ignored.rs',
                        "commit -q -m 'test: add the delta crate (base)'",
                        "commit -q -am 'test: change the delta crate (head)'"):
            with self.subTest(command=command):
                self.assert_mutation(self.pr, command, 'true', 'pr', 'recompute/r1')

    def small(self, setup, action='      - uses: ./\n', job='new'):
        return f'jobs:\n  {job}:\n    steps:\n{setup}{action}'

    def test_recompute_order_and_condition(self):
        needle = '        id: history\n'
        self.assert_mutation(self.pr, needle, needle + '        if: false\n', 'pr', 'recompute/r1')
        start = self.pr.index('      - name: Commit a base and a head around the delta crate')
        end = self.pr.index('      # No baseline artifact', start)
        block = self.pr[start:end]
        text = self.pr[:start] + self.pr[end:] + '\n' + block
        self.assertTrue(any(e.startswith('recompute/r1:') for e in check(text, 'pr')[1]))

    def test_new_jobs_and_order(self):
        checkout = '      - uses: actions/checkout@v7\n'
        prepare = '      - run: bash tests/prepare-fat-crate.sh\n'
        action = '      - uses: ./\n'
        for setup, tail in [('', action), (checkout, action + prepare),
                            (prepare + checkout, action),
                            (checkout + prepare + checkout, action),
                            (checkout + prepare + '        if: false\n', action),
                            (checkout + prepare + '        working-directory: elsewhere\n', action),
                            (checkout + '        if: false\n' + prepare, action)]:
            with self.subTest(setup=setup):
                self.assertTrue(check(self.small(setup, tail), 'integration')[1])
        self.assertEqual(check(self.small(checkout + prepare), 'integration')[1], [])
        self.assertEqual(check(self.small(checkout, action + '        with:\n          run-coverage: false\n'), 'integration')[1], [])
        self.assertEqual(check(self.small(checkout), 'pr')[1], ['new/line 5: unclassified PR fixture scenario'])
        self.assertEqual(check(self.small(checkout + prepare, job='"new"'), 'integration')[1], [])
        self.assertEqual(check(self.small(checkout, '      - run: true\n'), 'integration')[0], [])

    def test_extra_must_precede_consumers(self):
        call_text = '        run: bash tests/write-pr-fixtures.sh extra'
        self.assertIn(call_text, self.pr)
        text = self.pr.replace(call_text, '        run: true', 1)
        insertion = "      - name: 'P6. The same without the filter'"
        text = text.replace(insertion, '      - run: bash tests/write-pr-fixtures.sh extra\n\n' + insertion)
        _, errors = check(text, 'pr')
        self.assertEqual([e.split(':')[0] for e in errors], ['pull-request/p5'])

    def test_unsupported_layout(self):
        with self.assertRaises(ValueError):
            check('jobs:\n  a: {steps: []}\n', 'integration')
        with self.assertRaises(ValueError):
            check(self.small('', '      - {uses: ./}\n'), 'integration')


if __name__ == '__main__':
    unittest.main(verbosity=2)
