## Key Patterns Demonstrated

### 1. **Primary Use Case: External Data Sources**
- Identity provider queries (Auth0)
- External API calls
- Database queries requiring user context
- **Pattern**: `count = data.coder_workspace.me.name != "default" ? 1 : 0`

### 2. **Hardware Resource Considerations**
- **Most cases**: Create resources during prebuilds for validation
- **Expensive resources**: Skip during prebuilds to save costs
- **Flexible approach**: Use smaller resources for prebuilds

### 3. **Safe Resource Usage**
- Always use `length()` checks when accessing conditional data
- Provide fallback values for validation mode
- Use `merge()` for conditional environment variables

## When to Skip Hardware During Prebuilds

**Skip when:**
- Very expensive resources (GPU instances, large databases)
- Resources that take a long time to provision
- Resources that aren't needed for prebuild validation

**Don't skip when:**
- Basic compute instances (validation is more important than cost)
- Network resources (security groups, subnets)
- Storage that affects application behavior

The template validation benefit usually outweighs the prebuild cost for standard resources.
