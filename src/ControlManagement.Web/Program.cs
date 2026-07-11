using ControlManagement.Security;
using ControlManagement.Web.Security;
using ControlManagement.Web.Services;
using Microsoft.AspNetCore.HttpOverrides;
using System.Threading.RateLimiting;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.Logging.AddConsole();
builder.Logging.AddDebug();
builder.Services.AddControllersWithViews();
builder.Services.AddAntiforgery(options => options.HeaderName = "X-CSRF-TOKEN");
builder.Services.AddHttpClient<SecureRepositoryClient>();
builder.Services.AddHttpClient<AuthApiClient>();
builder.Services.Configure<SecurityOptions>(builder.Configuration.GetSection(SecurityOptions.SectionName));
builder.Services.AddSingleton<EnvelopeCrypto>();
builder.Services.AddSingleton<SignedAccessTokenService>();
builder.Services.AddSingleton<PermissionPolicy>();
builder.Services.AddSingleton<NavigationContextProtector>();
builder.Services.AddScoped<ControlMenuService>();
builder.Services.AddRateLimiter(options =>
{
    options.AddPolicy("login", context => RateLimitPartition.GetFixedWindowLimiter(
        context.Connection.RemoteIpAddress?.ToString() ?? "unknown",
        _ => new FixedWindowRateLimiterOptions { PermitLimit = 5, Window = TimeSpan.FromMinutes(1), QueueLimit = 0 }));
    options.AddPolicy("gateway", context => RateLimitPartition.GetFixedWindowLimiter(
        context.Connection.RemoteIpAddress?.ToString() ?? "unknown",
        _ => new FixedWindowRateLimiterOptions { PermitLimit = 120, Window = TimeSpan.FromMinutes(1), QueueLimit = 0 }));
});
builder.Services.Configure<ForwardedHeadersOptions>(options =>
    options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto);
builder.Services.AddSession(options =>
{
    options.Cookie.Name = ".ControlManagement.Session";
    options.Cookie.HttpOnly = true;
    options.Cookie.IsEssential = true;
    options.Cookie.SameSite = SameSiteMode.Strict;
    options.Cookie.SecurePolicy = builder.Environment.IsDevelopment() ? CookieSecurePolicy.SameAsRequest : CookieSecurePolicy.Always;
    options.IdleTimeout = TimeSpan.FromMinutes(30);
});
var app = builder.Build();
app.UseForwardedHeaders();
var pathBase = app.Configuration["Hosting:PathBase"];
if (!string.IsNullOrWhiteSpace(pathBase)) app.UsePathBase(pathBase);
if (!app.Environment.IsDevelopment())
{
    app.UseExceptionHandler("/Home/Error");
    app.UseHsts();
    app.UseHttpsRedirection();
}
app.Use(async (context, next) =>
{
    context.Response.Headers.XContentTypeOptions = "nosniff";
    context.Response.Headers.XFrameOptions = "DENY";
    context.Response.Headers["Referrer-Policy"] = "strict-origin-when-cross-origin";
    context.Response.Headers["Permissions-Policy"] = "camera=(), microphone=(), geolocation=()";
    context.Response.Headers["Content-Security-Policy"] =
        "default-src 'self'; style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://cdn.jsdelivr.net https://cdnjs.cloudflare.com; font-src 'self' https://fonts.gstatic.com https://cdn.jsdelivr.net https://cdnjs.cloudflare.com; script-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'";
    await next();
});
app.UseStaticFiles();
app.UseRouting();
app.UseSession();
app.UseRateLimiter();
app.UseAuthorization();
// First-login guard: if the user's session is flagged for a forced password
// change, only the change-password and logout paths are reachable.  Everything
// else is redirected back to /Account/ChangePassword.
app.Use(async (context, next) =>
{
    if (!string.IsNullOrEmpty(context.Session.GetString(ControlManagement.Web.Security.SessionIdentity.PasswordChangeRequiredKey)))
    {
        var path = context.Request.Path.Value ?? "";
        var allowed = path.StartsWith("/Account/ChangePassword", StringComparison.OrdinalIgnoreCase)
                      || path.StartsWith("/Login/Logout", StringComparison.OrdinalIgnoreCase)
                      || path.StartsWith("/css/", StringComparison.OrdinalIgnoreCase)
                      || path.StartsWith("/js/", StringComparison.OrdinalIgnoreCase)
                      || path.StartsWith("/lib/", StringComparison.OrdinalIgnoreCase);
        if (!allowed)
        {
            context.Response.Redirect("/Account/ChangePassword");
            return;
        }
    }
    await next();
});
app.MapControllerRoute("default", "{controller=Login}/{action=Index}/{areaKey?}");
app.Run();
