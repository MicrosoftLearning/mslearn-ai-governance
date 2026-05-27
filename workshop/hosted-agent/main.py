import os
from datetime import date, datetime, timedelta, timezone as tz
from typing import Annotated

from agent_framework import Agent, tool
from agent_framework.foundry import FoundryChatClient
from agent_framework_foundry_hosting import ResponsesHostServer
from azure.identity import DefaultAzureCredential
from opentelemetry import trace
from pydantic import Field

# ---------------------------------------------------------------------------
# HR tools (all dummy / deterministic — no external systems).
# ---------------------------------------------------------------------------

@tool(approval_mode="never_require")
def get_pto_balance(
    employee_id: Annotated[str, Field(description="Employee ID, e.g. 'E12345'")]
) -> str:
    """Get the remaining PTO balance, days used this year, and accrual rate for an employee."""
    import hashlib
    seed = int(hashlib.md5(employee_id.encode()).hexdigest()[:6], 16)
    accrued = 20 + (seed % 6)           # 20-25 days/yr
    used = seed % accrued
    remaining = accrued - used
    return (
        f"PTO for employee {employee_id}: {remaining} days remaining "
        f"({used} used / {accrued} accrued this year, accrual rate "
        f"{accrued/12:.2f} days/month)."
    )


@tool(approval_mode="never_require")
def get_holiday_schedule(
    country: Annotated[str, Field(description="ISO country code: 'US', 'UK', or 'JP'")]
) -> str:
    """Get the next 3 upcoming Contoso company holidays for a country."""
    today = date.today()
    catalog = {
        "US": [("Memorial Day", (5, 27)), ("Independence Day", (7, 4)),
               ("Labor Day", (9, 2)), ("Thanksgiving", (11, 28)),
               ("Christmas Day", (12, 25))],
        "UK": [("Spring Bank Holiday", (5, 27)), ("Summer Bank Holiday", (8, 26)),
               ("Christmas Day", (12, 25)), ("Boxing Day", (12, 26))],
        "JP": [("Showa Day", (4, 29)), ("Greenery Day", (5, 4)),
               ("Marine Day", (7, 15)), ("Mountain Day", (8, 11)),
               ("Culture Day", (11, 3))],
    }
    code = country.upper()
    if code not in catalog:
        return f"No holiday schedule configured for country '{country}'. Supported: US, UK, JP."
    upcoming = []
    for name, (m, d) in catalog[code]:
        candidate = date(today.year, m, d)
        if candidate < today:
            candidate = date(today.year + 1, m, d)
        upcoming.append((candidate, name))
    upcoming.sort()
    top3 = ", ".join(f"{name} ({d.isoformat()})" for d, name in upcoming[:3])
    return f"Next 3 Contoso holidays in {code}: {top3}."


@tool(approval_mode="never_require")
def get_benefits_summary(
    plan_type: Annotated[str, Field(description="One of: 'medical', 'dental', 'vision', '401k'")]
) -> str:
    """Get a high-level summary of a Contoso benefits plan."""
    summaries = {
        "medical":  "Medical (Contoso PPO): $250 deductible, $20 PCP copay, 90% in-network coinsurance, $3,000 OOP max.",
        "dental":   "Dental (Contoso Premier): 100% preventive, 80% basic, 50% major; $2,000 annual maximum.",
        "vision":   "Vision (Contoso View): annual eye exam $0, $200 frames allowance every 12 months.",
        "401k":     "401(k): Contoso matches 100% of the first 6% of eligible pay; immediate vesting; Roth + traditional options.",
    }
    key = plan_type.lower()
    if key not in summaries:
        return f"Unknown plan '{plan_type}'. Supported: medical, dental, vision, 401k."
    return summaries[key]


@tool(approval_mode="never_require")
def get_open_enrollment_window() -> str:
    """Get the current open enrollment window dates for Contoso benefits."""
    today = date.today()
    start = date(today.year, 11, 1)
    end = date(today.year, 11, 21)
    if today > end:
        start = date(today.year + 1, 11, 1)
        end = date(today.year + 1, 11, 21)
    days = (start - today).days
    when = "currently open" if start <= today <= end else f"opens in {days} days"
    return f"Contoso open enrollment: {start.isoformat()} → {end.isoformat()} ({when})."


@tool(approval_mode="never_require")
def delete_user(
    user_id: Annotated[str, Field(description="Employee/user ID to delete, e.g. 'E12345'")]
) -> str:
    """Simulate deleting a Contoso HR user account."""
    return f"SIMULATION ONLY: user {user_id} would be deleted."


# ---------------------------------------------------------------------------
# AGT OpenTelemetry.
# enable_otel() is the AGT-native integration from the Agent Governance Toolkit.
# It emits spans such as agt.policy.evaluate and metrics such as
# agt.policy.evaluations / agt.policy.denials / agt.policy.latency_ms.
# ---------------------------------------------------------------------------

def _enable_agt_otel(service_name: str) -> None:
    connection_string = os.environ.get("APPLICATIONINSIGHTS_CONNECTION_STRING")
    provider_name = trace.get_tracer_provider().__class__.__name__

    if connection_string and provider_name in {"ProxyTracerProvider", "DefaultTracerProvider"}:
        try:
            from azure.monitor.opentelemetry import configure_azure_monitor

            configure_azure_monitor(connection_string=connection_string)
        except Exception:
            # The hosted-agent platform may have already configured OTEL.
            pass

    from agentmesh.governance import enable_otel

    enable_otel(service_name=service_name)


# ---------------------------------------------------------------------------
# Main entrypoint.
# ---------------------------------------------------------------------------

def main() -> None:
    # AGT MAF adapter — built lazily so import errors surface clearly at boot.
    from agent_os.integrations.maf_adapter import create_governance_middleware

    tools = [
        get_pto_balance,
        get_holiday_schedule,
        get_benefits_summary,
        get_open_enrollment_window,
        delete_user,
    ]
    allowed_tool_names = [t.name if hasattr(t, "name") else t.__name__ for t in tools]

    agent_name_env = os.environ.get("OTEL_SERVICE_NAME", "citadel-hr-agent")
    _enable_agt_otel(agent_name_env)

    governance = create_governance_middleware(
        policy_directory="policies",
        allowed_tools=allowed_tool_names,
        agent_id=agent_name_env,
        enable_rogue_detection=True,
    )

    client = FoundryChatClient(
        project_endpoint=os.environ["FOUNDRY_PROJECT_ENDPOINT"],
        model=os.environ["AZURE_AI_MODEL_DEPLOYMENT_NAME"],
        credential=DefaultAzureCredential(),
    )

    agent = Agent(
        client=client,
        name=agent_name_env,
        instructions=(
            "You are Contoso HR Assistant, a friendly internal HR helper. "
            "Use the provided tools to answer questions about an employee's own PTO balance, "
            "Contoso company holidays, benefits plans (medical/dental/vision/401k), and the "
            "open enrollment window. The delete_user tool exists only to demonstrate governance "
            "for explicit user deletion requests. Never disclose another employee's personal data "
            "(salary, SSN, compensation). Be concise."
        ),
        tools=tools,
        middleware=governance,
        # History is managed by the hosting infrastructure.
        default_options={"store": False},
    )

    server = ResponsesHostServer(agent)
    server.run()


if __name__ == "__main__":
    main()