using System.IO.Pipelines;
using System.Net.Http.Headers;
using Microsoft.Extensions.Time.Testing;

namespace NodePrint.Core.Tests;

public sealed class IdleTests
{
    private static ByteArrayContent PdfBody()
    {
        var content = new ByteArrayContent("%PDF-1.4 test"u8.ToArray());
        content.Headers.ContentType = new MediaTypeHeaderValue("application/pdf");
        return content;
    }

    [Fact]
    public async Task A_job_is_in_flight_from_the_moment_its_request_arrives()
    {
        var clock = new FakeTimeProvider();
        await using var host = await TestHost.StartAsync(new FakeBackend(), clock: clock);
        var body = new Pipe();
        var content = new StreamContent(body.Reader.AsStream());
        content.Headers.ContentType = new MediaTypeHeaderValue("application/pdf");

        var sending = host.Client.PostAsync("/print?channel=label", content);
        await body.Writer.WriteAsync("%PDF-1.4"u8.ToArray());

        Assert.True(SpinWait.SpinUntil(() => !host.Service.IsIdle(clock.GetUtcNow()), TimeSpan.FromSeconds(5)));
        await body.Writer.CompleteAsync();
        await sending;
    }

    [Theory]
    [InlineData(4, false)]
    [InlineData(5, true)]
    public async Task The_app_is_idle_again_5_minutes_after_the_last_job_ended_whatever_its_outcome(int minutes, bool idle)
    {
        var clock = new FakeTimeProvider();
        await using var host = await TestHost.StartAsync(new FakeBackend(), clock: clock);

        await host.Client.PostAsync("/print?channel=nope", PdfBody());
        clock.Advance(TimeSpan.FromMinutes(minutes));

        Assert.Equal(idle, host.Service.IsIdle(clock.GetUtcNow()));
    }

    [Fact]
    public async Task The_app_is_idle_when_no_job_came_since_it_started()
    {
        var clock = new FakeTimeProvider();
        await using var host = await TestHost.StartAsync(new FakeBackend(), clock: clock);

        await host.Client.GetAsync("/status");

        Assert.True(host.Service.IsIdle(clock.GetUtcNow()));
    }
}
