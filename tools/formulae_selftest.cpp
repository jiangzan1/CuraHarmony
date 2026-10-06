// Self-test for the CuraHarmony formulae-engine / scripta / zeus_expected substitutes.
// Compiled (not linked) with the HarmonyOS clang to validate the API surface and the evaluator.

#include <cassert>
#include <iostream>
#include <string>

#include <cura-formulae-engine/eval.h>
#include <cura-formulae-engine/parser/parser.h>
#include <scripta/logger.h>
#include <zeus/expected.hpp>

int main()
{
    namespace cfe = CuraFormulaeEngine;

    // 1) Arithmetic on literals, evaluated against an empty variable map.
    cfe::env::EnvironmentMap empty;
    const zeus::expected<cfe::ast::ExprPtr, cfe::parser::error_t> arithmetic = cfe::parser::parse("1 + 2 * 3");
    assert(arithmetic.has_value());
    const cfe::eval::Result arithmetic_result = arithmetic.value().evaluate(&empty);
    assert(arithmetic_result.has_value());
    assert(arithmetic_result.value().toString() == "7");

    // 2) Comparison against a variable coming from the environment.
    cfe::env::LocalEnvironment environment(&cfe::env::std_env);
    environment.set("material_print_temperature", static_cast<std::int64_t>(210));

    const zeus::expected<cfe::ast::ExprPtr, cfe::parser::error_t> comparison = cfe::parser::parse("material_print_temperature > 200");
    assert(comparison.has_value());
    const cfe::eval::Result comparison_result = comparison.value().evaluate(static_cast<const cfe::env::Environment *>(&environment));
    assert(comparison_result.has_value());
    assert(comparison_result.value().toBool());

    // 3) Ternary + quoted string.
    const zeus::expected<cfe::ast::ExprPtr, cfe::parser::error_t> ternary = cfe::parser::parse("true ? 'on' : 'off'");
    assert(ternary.has_value());
    const cfe::eval::Result ternary_result = ternary.value().evaluate(&environment);
    assert(ternary_result.has_value());
    assert(ternary_result.value().toString() == "on");

    // 4) Unknown variable must fail so that CuraEngine can fall back to the raw text.
    const zeus::expected<cfe::ast::ExprPtr, cfe::parser::error_t> unknown = cfe::parser::parse("does_not_exist + 1");
    assert(unknown.has_value());
    const cfe::eval::Result unknown_result = unknown.value().evaluate(&empty);
    assert(! unknown_result.has_value());

    // 5) A plain string that is not an expression at all must fail parsing.
    const zeus::expected<cfe::ast::ExprPtr, cfe::parser::error_t> not_an_expression = cfe::parser::parse("some plain text!");
    assert(! not_an_expression.has_value());

    // 6) scripta hooks are no-ops and must stay callable in the upstream shapes.
    scripta::log("trace", 0, 0, 0);
    scripta::log("trace", 0, 0, 0, scripta::CellVDI{ "flag", true }, scripta::PointVDI{ "count", 3 });
    scripta::setAll(1, 2, 3);

    std::cout << "formulae shim self-test ok" << std::endl;
    return 0;
}
