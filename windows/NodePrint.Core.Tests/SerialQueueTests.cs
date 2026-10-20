namespace NodePrint.Core.Tests;

public sealed class SerialQueueTests
{
    [Fact]
    public async Task Each_turn_waits_for_the_one_before()
    {
        var queue = new SerialQueue();
        var first = queue.Enter();
        var second = queue.Enter();

        Assert.True(first.Ready.IsCompleted);
        Assert.False(second.Ready.IsCompleted);
        first.Dispose();
        await second.Ready.WaitAsync(TimeSpan.FromSeconds(5));
    }

    [Fact]
    public async Task A_turn_given_up_early_does_not_let_the_next_one_jump_ahead()
    {
        var queue = new SerialQueue();
        var printing = queue.Enter();
        var abandoned = queue.Enter();
        var next = queue.Enter();

        abandoned.Dispose();

        Assert.False(next.Ready.IsCompleted);
        printing.Dispose();
        await next.Ready.WaitAsync(TimeSpan.FromSeconds(5));
    }
}
