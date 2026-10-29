library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity fifo_tb is
end entity fifo_tb;

architecture sim of fifo_tb is

  constant BYTE_SIZE  : integer := 8;
  constant FIFO_SIZE  : integer := 4;
  constant THRESHOLD  : integer := 2;
  constant CLK_PERIOD : time    := 10 ns;

  signal push          : std_logic := '0';
  signal pop           : std_logic := '0';
  signal byte_pl       : std_logic_vector(BYTE_SIZE-1 downto 0) := (others => '0');
  signal rst           : std_logic := '1';
  signal clk           : std_logic := '0';
  signal threshold_act : std_logic;
  signal empty         : std_logic;
  signal full          : std_logic;
  signal byte_out_pl   : std_logic_vector(BYTE_SIZE-1 downto 0);

  signal done : boolean := false;

begin

  dut : entity work.fifo
    generic map (
      byte_size => BYTE_SIZE,
      fifo_size => FIFO_SIZE,
      threshold => THRESHOLD
    )
    port map (
      push          => push,
      byte_pl       => byte_pl,
      rst           => rst,
      clk           => clk,
      threshold_act => threshold_act,
      empty         => empty,
      full          => full,
      pop           => pop,
      byte_out_pl   => byte_out_pl
    );

  clk_gen : process
  begin
    while not done loop
      clk <= '0';
      wait for CLK_PERIOD / 2;
      clk <= '1';
      wait for CLK_PERIOD / 2;
    end loop;
    wait;
  end process clk_gen;

  stim : process
    type model_t is array (0 to FIFO_SIZE-1) of integer;
    variable q        : model_t := (others => 0);
    variable cnt      : integer := 0;
    variable errors   : integer := 0;
    variable next_val : integer := 1;
    variable seed1    : positive := 7;
    variable seed2    : positive := 13;
    variable r        : real;
    variable rp, rq   : boolean;

    procedure check(cond : boolean; msg : string) is
    begin
      if not cond then
        report msg severity error;
        errors := errors + 1;
      end if;
    end procedure;

    procedure shift_model is
    begin
      for i in 0 to FIFO_SIZE-2 loop
        q(i) := q(i+1);
      end loop;
    end procedure;

    procedure cycle(do_push, do_pop : boolean; val : integer) is
      variable v        : integer := val mod 2**BYTE_SIZE;
      variable expected : integer := -1;
      variable got      : integer;
    begin
      if do_push then push <= '1'; else push <= '0'; end if;
      if do_pop  then pop  <= '1'; else pop  <= '0'; end if;
      byte_pl <= std_logic_vector(to_unsigned(v, BYTE_SIZE));

      wait until rising_edge(clk);
      wait for 1 ns;

      push <= '0';
      pop  <= '0';

      if do_push and do_pop then
        if cnt > 0 and cnt < FIFO_SIZE then
          expected := q(0);
          shift_model;
          q(cnt-1) := v;
        else
          report "EDGE CASE push+pop at size=" & integer'image(cnt)
               & ": empty=" & std_logic'image(empty)
               & " full="   & std_logic'image(full)
               & " out="    & integer'image(to_integer(unsigned(byte_out_pl)))
            severity note;
          return;
        end if;
      elsif do_push then
        if cnt < FIFO_SIZE then
          q(cnt) := v;
          cnt := cnt + 1;
        end if;
      elsif do_pop then
        if cnt > 0 then
          expected := q(0);
          shift_model;
          cnt := cnt - 1;
        end if;
      end if;

      if expected >= 0 then
        got := to_integer(unsigned(byte_out_pl));
        check(got = expected,
              "pop: expected " & integer'image(expected)
              & ", got " & integer'image(got));
      end if;

      check((empty = '1') = (cnt = 0),
            "empty=" & std_logic'image(empty) & " at size=" & integer'image(cnt));
      check((full = '1') = (cnt = FIFO_SIZE),
            "full=" & std_logic'image(full) & " at size=" & integer'image(cnt));
    end procedure;

    procedure do_reset is
    begin
      rst  <= '1';
      push <= '0';
      pop  <= '0';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      wait for 1 ns;
      rst <= '0';
      cnt := 0;
      check(empty = '1', "empty must be 1 after reset");
      check(full  = '0', "full must be 0 after reset");
    end procedure;

  begin

    report "Test 1: reset";
    do_reset;

    report "Test 2: fill until full (consecutive pushes)";
    for i in 1 to FIFO_SIZE loop
      cycle(true, false, next_val);
      next_val := next_val + 1;
    end loop;

    report "Test 3: push into full FIFO must be ignored";
    cycle(true, false, 200);

    report "Test 4: read everything, check order";
    for i in 1 to FIFO_SIZE loop
      cycle(false, true, 0);
    end loop;

    report "Test 5: pop from empty FIFO";
    cycle(false, true, 0);

    report "Test 6: simultaneous push and pop, partially filled";
    cycle(true, false, next_val); next_val := next_val + 1;
    cycle(true, false, next_val); next_val := next_val + 1;
    for i in 1 to 3 loop
      cycle(true, true, next_val);
      next_val := next_val + 1;
    end loop;
    cycle(false, true, 0);
    cycle(false, true, 0);

    report "Test 7: reset in the middle of operation";
    cycle(true, false, next_val); next_val := next_val + 1;
    cycle(true, false, next_val); next_val := next_val + 1;
    do_reset;
    cycle(false, true, 0);

    report "Test 8: random traffic, 1000 cycles";
    for i in 1 to 1000 loop
      uniform(seed1, seed2, r); rp := r < 0.5;
      uniform(seed1, seed2, r); rq := r < 0.5;
      if rp and rq and (cnt = 0 or cnt = FIFO_SIZE) then
        rq := false;
      end if;
      cycle(rp, rq, next_val);
      next_val := next_val + 1;
    end loop;

    report "Test 9: edge cases (print only, no checks)";
    do_reset;
    cycle(true, true, 111);
    do_reset;
    for i in 1 to FIFO_SIZE loop
      cycle(true, false, i);
    end loop;
    cycle(true, true, 222);
    do_reset;

    if errors = 0 then
      report "DONE: no errors" severity note;
    else
      report "DONE: errors = " & integer'image(errors) severity error;
    end if;

    done <= true;
    wait;
  end process stim;

end architecture sim;