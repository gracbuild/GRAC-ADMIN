using ControlManagement.Api.Security;
using ControlManagement.Api.Services;
using ControlManagement.Api.Validation;
using ControlManagement.Security;
using Microsoft.AspNetCore.HttpOverrides;

var builder = WebApplication.CreateBuilder(args);
builder.Logging.ClearProviders();
builder.Logging.AddConsole();
builder.Logging.AddDebug();
builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddCors(options =>
{
    options.AddPolicy("ControlManagementWeb", policy =>
    {
        var origins = builder.Configuration.GetSection("Cors:AllowedOrigins").Get<string[]>()
            ?? ["http://localhost:5043", "https://localhost:7182"];
        policy.WithOrigins(origins)
            .AllowAnyHeader()
            .AllowAnyMethod();
    });
});
builder.Services.AddScoped<IRegulatoryRepositoryService, RegulatoryRepositoryService>();
builder.Services.AddScoped<IAuthService, AuthService>();
builder.Services.AddScoped<RepositoryCommandValidator>();
builder.Services.AddMemoryCache();
builder.Services.Configure<SecurityOptions>(builder.Configuration.GetSection(SecurityOptions.SectionName));
builder.Services.AddSingleton<EnvelopeCrypto>();
builder.Services.AddSingleton<SignedAccessTokenService>();
builder.Services.AddSingleton<PermissionPolicy>();
builder.Services.AddSingleton<PasswordHasher>();
builder.Services.Configure<ForwardedHeadersOptions>(options =>
    options.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto);

var app = builder.Build();
app.UseForwardedHeaders();
app.UseCors("ControlManagementWeb");
if (!app.Environment.IsDevelopment())
{
    app.UseHsts();
    app.UseHttpsRedirection();
}
app.Use(async (context, next) =>
{
    context.Response.Headers.XContentTypeOptions = "nosniff";
    context.Response.Headers.XFrameOptions = "DENY";
    context.Response.Headers.CacheControl = "no-store";
    await next();
});
app.MapControllers();
app.MapGet("/", () => Results.Ok(new { status = "ready" }));
app.Run();
