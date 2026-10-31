library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity uart_rx_tb is
end entity uart_rx_tb;

architecture sim of uart_rx_tb is

  constant FREQ       : natural   := 50000000;
  constant BAUD       : positive  := 115200;
  constant DATA_BITS  : integer   := 8;
  constant STOP_BITS  : integer   := 1;
  constant EN_PARITY  : integer := 1;
  constant PARITY_T   : std_logic := '0';
  constant FIFO_SIZE  : integer   := 16;
  constant THRESHOLD  : integer   := 4;

  constant CLK_PERIOD : time := 1 sec / FREQ;
  constant BIT_TIME   : time := 1 sec / BAUD;

  signal clk           : std_logic := '0';
  signal rx_line       : std_logic := '1';
  signal data_byte     : std_logic_vector(DATA_BITS-1 downto 0);
  signal pop           : std_logic;
  signal pop_m         : std_logic := '0';
  signal pop_c         : std_logic := '0';
  signal empty         : std_logic;
  signal pop_err       : std_logic;
  signal threshold_act : std_logic;
  signal en_uart       : std_logic := '0';
  signal uart_err      : std_logic;

  signal done         : boolean := false;
  signal consumer_on  : boolean := false;
  signal rcv_count    : natural := 0;
  signal c_errors     : natural := 0;

  function frame_bits return integer is
  begin
    if EN_PARITY = 1 then
      return 2 + DATA_BITS + STOP_BITS;
    end if;
    return 1 + DATA_BITS + STOP_BITS;
  end function;

  constant NB : integer := frame_bits;

  function lcg(i : natural) return integer is
  begin
    return (i * 73 + 41 + (i / 7) * 13) mod 2**DATA_BITS;
  end function;

begin

  pop <= pop_m or pop_c;

  dut : entity work.uart_rx
    generic map (
      freq          => FREQ,
      baud          => BAUD,
      amm_data_bits => DATA_BITS,
      amm_stop_bits => STOP_BITS,
      en_pairity    => EN_PARITY,
      pairity_t     => PARITY_T,
      fifo_size     => FIFO_SIZE,
      threshold     => THRESHOLD
    )
    port map (
      clk           => clk,
      rx_line_async       => rx_line,
      data_byte     => data_byte,
      pop           => pop,
      empty         => empty,
      pop_err       => pop_err,
      threshold_act => threshold_act,
      en_uart       => en_uart,
      uart_err      => uart_err
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

  consumer : process
    variable s1, s2 : positive := 3;
    variable r      : real;
    variable idx    : natural := 0;
    variable errs   : natural := 0;
    variable popped : boolean := false;
    variable got    : integer;
  begin
    s2 := 17;
    loop
      wait until rising_edge(clk);
      wait for 1 ns;
      if popped then
        got := to_integer(unsigned(data_byte));
        if got /= lcg(idx) then
          errs := errs + 1;
          report "consumer: byte #" & integer'image(idx) & " expected " & integer'image(lcg(idx))
               & ", got " & integer'image(got) severity error;
        end if;
        idx := idx + 1;
        rcv_count <= idx;
        c_errors <= errs;
      end if;
      popped := false;
      if consumer_on and empty = '0' then
        uniform(s1, s2, r);
        if r < 0.3 then
          pop_c <= '1';
          popped := true;
        else
          pop_c <= '0';
        end if;
      else
        pop_c <= '0';
      end if;
    end loop;
  end process consumer;

  stim : process
    type model_t is array (0 to FIFO_SIZE-1) of integer;
    variable q           : model_t := (others => 0);
    variable cnt         : integer := 0;
    variable errors      : integer := 0;
    variable err_exp     : boolean := false;
    variable pop_err_exp : boolean := false;
    variable seed1       : positive := 11;
    variable seed2       : positive := 29;
    variable r           : real;
    variable v           : integer;
    variable k           : integer;
    variable base        : natural;


    procedure check(cond : boolean; msg : string) is
    begin
      if not cond then
        report msg severity error;
        errors := errors + 1;
      end if;
    end procedure;

    procedure model_push(val : integer) is
    begin
      if cnt < FIFO_SIZE then
        q(cnt) := val;
        cnt := cnt + 1;
      else
        for i in 0 to FIFO_SIZE-2 loop
          q(i) := q(i+1);
        end loop;
        q(FIFO_SIZE-1) := val;
      end if;
    end procedure;

    function parity_bit(val : integer) return std_logic is
      variable bits : std_logic_vector(DATA_BITS-1 downto 0);
      variable p    : std_logic := PARITY_T;
    begin
      bits := std_logic_vector(to_unsigned(val, DATA_BITS));
      for i in 0 to DATA_BITS-1 loop
        p := p xor bits(i);
      end loop;
      return p;
    end function;

    procedure rand_int(lo, hi : integer; res : out integer) is
    begin
      uniform(seed1, seed2, r);
      res := lo + integer(floor(r * real(hi - lo + 1)));
    end procedure;

    procedure frame(val : integer; bt : time; parity_ok : boolean; stop_ok : boolean;
                    jit_permille : natural := 0; spikes : boolean := false) is
      type lv_t is array (0 to NB-1) of std_logic;
      variable bits   : std_logic_vector(DATA_BITS-1 downto 0);
      variable lv     : lv_t;
      variable t_prev : time := 0 fs;
      variable t_k    : time;
      variable j      : integer;
    begin
      bits := std_logic_vector(to_unsigned(val, DATA_BITS));
      lv(0) := '0';
      for i in 0 to DATA_BITS-1 loop
        lv(1 + i) := bits(i);
      end loop;
      if EN_PARITY = 1 then
        if parity_ok then
          lv(1 + DATA_BITS) := parity_bit(val);
        else
          lv(1 + DATA_BITS) := not parity_bit(val);
        end if;
      end if;
      for s in 0 to STOP_BITS-1 loop
        lv(NB - STOP_BITS + s) := '1';
      end loop;
      if not stop_ok then
        lv(NB - STOP_BITS) := '0';
      end if;

      for i in 0 to NB-1 loop
        if i = 0 or jit_permille = 0 then
          j := 0;
        else
          rand_int(-integer(jit_permille), integer(jit_permille), j);
        end if;
        t_k := bt * i + bt * j / 1000;
        if t_k > t_prev then
          wait for t_k - t_prev;
        end if;
        rx_line <= lv(i);
        t_prev := t_k;
        if spikes and i > 0 then
          wait for bt / 10;
          rx_line <= not lv(i);
          wait for bt * 15 / 100;
          rx_line <= lv(i);
          t_prev := t_k + bt / 4;
        end if;
      end loop;
      if bt * NB > t_prev then
        wait for bt * NB - t_prev;
      end if;
      rx_line <= '1';
    end procedure;

    procedure good_frame(val : integer; bt : time := BIT_TIME;
                         jit_permille : natural := 0; spikes : boolean := false) is
    begin
      frame(val, bt, true, true, jit_permille, spikes);
      model_push(val);
      err_exp := false;
    end procedure;

    procedure bad_frame(val : integer; bad_parity : boolean) is
    begin
      if bad_parity then
        frame(val, BIT_TIME, false, true);
      else
        frame(val, BIT_TIME, true, false);
      end if;
      err_exp := true;
      wait for BIT_TIME * 3 / 2;
    end procedure;

    procedure check_state(tag : string) is
    begin
      check((empty = '1') = (cnt = 0),
            tag & ": empty=" & std_logic'image(empty) & " at size=" & integer'image(cnt));
      check((threshold_act = '1') = (cnt > THRESHOLD),
            tag & ": threshold_act=" & std_logic'image(threshold_act) & " at size=" & integer'image(cnt));
      check((uart_err = '1') = err_exp,
            tag & ": uart_err=" & std_logic'image(uart_err) & ", expected " & boolean'image(err_exp));
      check((pop_err = '1') = pop_err_exp,
            tag & ": pop_err=" & std_logic'image(pop_err) & ", expected " & boolean'image(pop_err_exp));
    end procedure;

    procedure settle(tag : string) is
    begin
      wait for BIT_TIME;
      wait until rising_edge(clk);
      wait for 1 ns;
      check_state(tag);
    end procedure;

    procedure do_pop(tag : string) is
      variable expected : integer;
      variable got      : integer;
    begin
      pop_m <= '1';
      wait until rising_edge(clk);
      wait for 1 ns;
      pop_m <= '0';
      if cnt > 0 then
        expected := q(0);
        for i in 0 to FIFO_SIZE-2 loop
          q(i) := q(i+1);
        end loop;
        cnt := cnt - 1;
        pop_err_exp := false;
        got := to_integer(unsigned(data_byte));
        check(got = expected,
              tag & ": data expected " & integer'image(expected) & ", got " & integer'image(got));
      else
        pop_err_exp := true;
      end if;
      check_state(tag);
    end procedure;

    procedure pop_all(tag : string) is
    begin
      while cnt > 0 loop
        do_pop(tag);
      end loop;
    end procedure;

    procedure sweep(tag : string; bt : time; grp : natural; jit : natural; spikes : boolean) is
      variable n : natural := 0;
    begin
      for val in 0 to 2**DATA_BITS - 1 loop
        good_frame(val, bt, jit, spikes);
        n := n + 1;
        if n = grp then
          settle(tag & " value=" & integer'image(val));
          pop_all(tag);
          n := 0;
        end if;
      end loop;
      settle(tag & " end");
      pop_all(tag);
    end procedure;

    procedure glitch(len : time; tag : string) is
    begin
      rx_line <= '0';
      wait for len;
      rx_line <= '1';
      wait for BIT_TIME;
      settle(tag & " glitch");
      good_frame(16#5A#);
      settle(tag & " frame after glitch");
      pop_all(tag);
    end procedure;

  begin

    for i in 1 to 10 loop
      wait until rising_edge(clk);
    end loop;
    en_uart <= '1';
    for i in 1 to 10 loop
      wait until rising_edge(clk);
    end loop;

    report "Test 1: idle after start";
    settle("T1");

    report "Test 2: all values, exact baud, groups of 8 back-to-back";
    sweep("T2", BIT_TIME, 8, 0, false);

    report "Test 3: all values, baud +4%";
    sweep("T3 +4%", BIT_TIME * 104 / 100, 8, 0, false);

    report "Test 4: all values, baud -4%";
    sweep("T4 -4%", BIT_TIME * 96 / 100, 8, 0, false);

    report "Test 5: every edge jittered by up to +-15% of a bit";
    for i in 1 to 128 loop
      rand_int(0, 2**DATA_BITS - 1, v);
      good_frame(v, BIT_TIME, 150, false);
      if i mod 8 = 0 then
        settle("T5");
        pop_all("T5");
      end if;
    end loop;

    report "Test 6: inverted spike near the start of every bit";
    for i in 1 to 64 loop
      rand_int(0, 2**DATA_BITS - 1, v);
      good_frame(v, BIT_TIME, 0, true);
      if i mod 8 = 0 then
        settle("T6");
        pop_all("T6");
      end if;
    end loop;

    report "Test 7: jitter +-10% together with baud +-2%";
    for i in 1 to 64 loop
      rand_int(0, 2**DATA_BITS - 1, v);
      if i mod 2 = 0 then
        good_frame(v, BIT_TIME * 102 / 100, 100, false);
      else
        good_frame(v, BIT_TIME * 98 / 100, 100, false);
      end if;
      if i mod 8 = 0 then
        settle("T7");
        pop_all("T7");
      end if;
    end loop;

    report "Test 8: glitches of different length in idle";
    glitch(CLK_PERIOD, "T8 1clk");
    glitch(CLK_PERIOD * 3, "T8 3clk");
    glitch(BIT_TIME / 10, "T8 0.10bit");
    glitch(BIT_TIME / 4, "T8 0.25bit");
    glitch(BIT_TIME * 4 / 10, "T8 0.40bit");

    report "Test 9: break (line low for 3 frames)";
    rx_line <= '0';
    wait for BIT_TIME * NB * 3;
    rx_line <= '1';
    err_exp := true;
    wait for BIT_TIME * 2;
    settle("T9 break");
    good_frame(16#3C#);
    settle("T9 recovery");
    pop_all("T9");

    report "Test 10: error storm";
    for i in 1 to 40 loop
      rand_int(0, 2**DATA_BITS - 1, v);
      rand_int(0, 2, k);
      if k = 0 then
        bad_frame(v, false);
      elsif k = 1 and EN_PARITY = 1 then
        bad_frame(v, true);
      else
        good_frame(v);
      end if;
      settle("T10");
      if cnt > 10 then
        pop_all("T10");
      end if;
    end loop;
    pop_all("T10 end");

    report "Test 11: en_uart toggling";
    for i in 1 to 50 loop
      en_uart <= not en_uart;
      wait for CLK_PERIOD * (1 + i mod 7);
    end loop;
    en_uart <= '1';
    settle("T11 toggled in idle");
    en_uart <= '0';
    wait for BIT_TIME;
    frame(16#99#, BIT_TIME, true, true);
    settle("T11 disabled");
    en_uart <= '1';
    wait for BIT_TIME;
    for i in 1 to 10 loop
      en_uart <= '0' after BIT_TIME * (i mod 10) + BIT_TIME / 2, '1' after BIT_TIME * (i mod 10) + BIT_TIME;
      rand_int(0, 2**DATA_BITS - 1, v);
      good_frame(v);
      wait for BIT_TIME;
    end loop;
    en_uart <= '1';
    settle("T11 toggled inside frames");
    pop_all("T11");

    report "Test 12: massive overflow, only newest FIFO_SIZE bytes survive";
    for i in 1 to 3 * FIFO_SIZE loop
      good_frame(i mod 2**DATA_BITS);
    end loop;
    settle("T12");
    pop_all("T12");

    report "Test 13: 300 back-to-back frames read concurrently";
    base := rcv_count;
    consumer_on <= true;
    for i in 0 to 299 loop
      frame(lcg(base + i), BIT_TIME, true, true);
    end loop;
    wait until rcv_count = base + 300 for BIT_TIME * NB * 4;
    consumer_on <= false;
    wait for BIT_TIME;
    check(rcv_count = base + 300,
          "T13: consumer received " & integer'image(rcv_count - base) & " of 300");
    check(c_errors = 0, "T13: consumer data errors = " & integer'image(c_errors));
    err_exp := false;
    pop_err_exp := false;
    settle("T13");

    report "Test 14: random mix";
    for i in 1 to 300 loop
      rand_int(0, 2**DATA_BITS - 1, v);
      uniform(seed1, seed2, r);
      if r < 0.08 then
        bad_frame(v, false);
      elsif r < 0.16 and EN_PARITY = 1 then
        bad_frame(v, true);
      else
        if r > 0.6 then
          good_frame(v, BIT_TIME, 50, true);
        else
          rand_int(0, 60, k);
          good_frame(v, BIT_TIME * (970 + k) / 1000, 50, false);
        end if;
        uniform(seed1, seed2, r);
        if r < 0.3 then
          settle("T14");
          rand_int(0, cnt, k);
          for j in 1 to k loop
            do_pop("T14");
          end loop;
        end if;
      end if;
    end loop;
    settle("T14 end");
    pop_all("T14 end");

    if errors = 0 then
      report "DONE: no errors" severity note;
    else
      report "DONE: errors = " & integer'image(errors) severity error;
    end if;

    done <= true;
    wait;
  end process stim;

end architecture sim;