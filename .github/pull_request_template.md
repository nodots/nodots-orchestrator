Closes #

## Checklist

- [ ] A fix for a failure found in practice adds an eval case, or states in one line why not.
- [ ] PR title starting `[READY]:` and carrying the package ID, body linking the package issue.
- [ ] One PR comment carries the stamp, first line machine-readable: `VERIFIED: <suite or run id> @ <full head sha>`, then the command you ran and its summary output.
- [ ] A push after the stamp voids it. Re-run and re-stamp so a current stamp exists for the present head sha.
