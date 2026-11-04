// SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
// SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
//
// RunAlloy — headless runner for the DS Alloy consistency models.
//
// For each .als file argument, execute every command in it:
//   `check X`  -> expect UNSAT (no counterexample);  SAT   = FAIL (a counterexample exists)
//   `run  X`   -> expect SAT   (an instance exists);  UNSAT = FAIL (the model is inconsistent)
// Exit 0 iff every command passed; non-zero otherwise. Uses the pure-Java SAT4J
// solver so no native SAT libraries are needed (headless-clean in a container).
//
// A MODEL WITH NO `run` FAILS. A `check` is UNSAT when its
// assertion has no counterexample, and also when the model's facts admit no
// instance at all; from the outside the two are the same PASS. The `run` is what
// tells them apart: an instance shows the facts are jointly satisfiable, so a
// model without one has checks that may hold of nothing. A file with no command
// at all is the same failure with nothing left to report, and is caught by the
// same count.
//
// This is the harness the ds-alloy image compiles from the mounted repo and runs
// (the alloy image's entrypoint). Kept here — not baked into the image — so it
// travels with the repo as the spec audits do.
//
// ALLOY_XML_DIR, when set, is where each SATISFIABLE command's solution is
// written as A4 XML — the counterexample of a failed `check`, the instance of
// a `run` — named cmd<N>.xml, N counting commands from 1 in the order they are
// printed. The dev-mcp driver sets it so dev-mcp can read the counterexample
// itself; the formal.build lane does not, and prints exactly what it did.

import edu.mit.csail.sdg.alloy4.A4Reporter;
import edu.mit.csail.sdg.ast.Command;
import edu.mit.csail.sdg.ast.Module;
import edu.mit.csail.sdg.parser.CompUtil;
import edu.mit.csail.sdg.translator.A4Options;
import edu.mit.csail.sdg.translator.A4Solution;
import edu.mit.csail.sdg.translator.TranslateAlloyToKodkod;
import kodkod.engine.satlab.SATFactory;

public class RunAlloy {
    public static void main(String[] args) throws Exception {
        A4Options opts = new A4Options();
        opts.solver = SATFactory.DEFAULT; // sat4j — pure Java, headless-clean

        String xmlDir = System.getenv("ALLOY_XML_DIR");
        int total = 0, failed = 0;
        for (String path : args) {
            Module world = CompUtil.parseEverything_fromFile(A4Reporter.NOP, null, path);
            System.out.println("== " + path + " ==");
            int runs = 0;
            for (Command cmd : world.getAllCommands()) {
                total++;
                if (!cmd.check) runs++;
                A4Solution sol = TranslateAlloyToKodkod.execute_command(
                        A4Reporter.NOP, world.getAllReachableSigs(), cmd, opts);
                boolean sat = sol.satisfiable();
                if (sat && xmlDir != null) {
                    // The model's functions, as the Alloy GUI passes them: the
                    // one-argument writeXML hands the writer a null list and it
                    // dereferences it (NPE on `extraSkolems`, Alloy 6). And a
                    // failure to write the XML must never change the verdict.
                    try {
                        sol.writeXML(xmlDir + "/cmd" + total + ".xml", world.getAllFunc());
                    } catch (Exception e) {
                        System.err.println("RunAlloy: could not write the instance XML: " + e);
                    }
                }
                boolean pass = cmd.check ? !sat : sat; // check wants UNSAT, run wants SAT
                String kind = cmd.check ? "check" : "run  ";
                String note = pass ? "PASS"
                        : (cmd.check ? "FAIL - counterexample found"
                                     : "FAIL - no instance (inconsistent)");
                System.out.printf("  %s %-30s %s%n", kind, cmd.label, note);
                if (!pass) failed++;
            }
            if (runs == 0) {
                // Counted as a command that failed, so the totals line and the
                // exit code both carry it.
                total++;
                failed++;
                System.out.printf("  %s %-30s %s%n", "run  ", "(none)",
                        "FAIL - no `run` in this model: nothing shows its facts"
                        + " are satisfiable, so its checks may hold of nothing");
            }
        }
        System.out.printf("alloy: %d/%d commands passed%n", total - failed, total);
        System.exit(failed == 0 ? 0 : 1);
    }
}
