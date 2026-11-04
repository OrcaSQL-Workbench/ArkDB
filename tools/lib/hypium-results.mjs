export function parseHypiumResults(text) {
  const normalized = text.replace(/\r\n?/g, '\n');
  const summary = normalized.match(
    /^Tests run: (\d+), Failure: (\d+), Error: (\d+), Pass: (\d+), Ignore: (\d+)\s*$/m);
  if (!summary) throw new Error('Native Hypium result summary is missing.');
  const [total, failures, errors, passed, ignored] = summary.slice(1).map(Number);
  const results = [...normalized.matchAll(/^result=(.+)$/gm)].map((match) => match[1]);
  if (total <= 0 || failures !== 0 || errors !== 0 || ignored !== 0 || passed !== total ||
    results.length !== total || results.some((result) => result !== 'Success')) {
    throw new Error(
      `Native Hypium verdict is unsuccessful or inconsistent: ${summary[0].trim()}`);
  }
  return { total, passed };
}
