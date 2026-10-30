library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity diag_tb is
end entity diag_tb;

architecture sim of diag_tb is

  constant FREQ       : natural  := 50000000;
  constant BAUD       : positive := 115200;
  constant DATA_BITS  : integer  := 8;
  constant STOP_BITS  : integer  := 1;
  constant FIFO_SIZE  : integer  := 16;
  constant SHOW_PASS  : boolean  := false;

  constant CLK_PERIOD : time := 1 sec / FREQ;
  constant BIT_TIME   : time := 1 sec / BAUD;
  constant FRAME_LEN  : integer := 2 + DATA_BITS + STOP_BITS;

  signal clk  : std_logic := '0';
  signal done : boolean := false;

  signal rx_e, rx_o           : std_logic := '1';
  signal data_e, data_o       : std_logic_vector(DATA_BITS-1 downto 0);
  signal pop_e, pop_o         : std_logic := '0';
  signal empty_e, empty_o     : std_logic;
  signal err_e, err_o         : std_logic;
  signal pushes_e, pushes_o   : natural := 0;
  signal ptime_e, ptime_o     : time := 0 ns;
  signal frame_start          : time := 0 ns;

  function bin(v : std_logic_vector) return string is
    variable s : string(1 to v'length);
    variable k : integer := 1;
  begin
    for i in v'range loop
      s(k) := std_logic'image(v(i))(2);
      k := k + 1;
    end loop;
    return s;
  end function;

  function bit_pos(t : time) return string is
  begin
    return integer'image(t * 100 / BIT_TIME / 100) & "." & integer'image(t * 100 / BIT_TIME mod 100);
  end function;

  function push_pos(n : natural; t : time) return string is
  begin
    if n = 0 then
      return "none";
    end if;
    return bit_pos(t);
  end function;

begin

  dut_e : entity work.uart_rx
    generic map (
      freq => FREQ, baud => BAUD, amm_data_bits => DATA_BITS, amm_stop_bits => STOP_BITS,
      en_pairity => '1', pairity_t => '0', fifo_size => FIFO_SIZE, threshold => 1
    )
    port map (
      clk => clk, rx_line_async => rx_e, data_byte => data_e, pop => pop_e, empty => empty_e,
      pop_err => open, threshold_act => open, en_uart => '1', uart_err => err_e
    );

  dut_o : entity work.uart_rx
    generic map (
      freq => FREQ, baud => BAUD, amm_data_bits => DATA_BITS, amm_stop_bits => STOP_BITS,
      en_pairity => '1', pairity_t => '1', fifo_size => FIFO_SIZE, threshold => 1
    )
    port map (
      clk => clk, rx_line_async => rx_o, data_byte => data_o, pop => pop_o, empty => empty_o,
      pop_err => open, threshold_act => open, en_uart => '1', uart_err => err_o
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

  mon_e : process
    alias p is << signal .diag_tb.dut_e.push : std_logic >>;
    variable n : natural := 0;
  begin
    wait until rising_edge(clk);
    if p = '1' then
      n := n + 1;
      pushes_e <= n;
      ptime_e <= now - frame_start;
    end if;
  end process mon_e;

  mon_o : process
    alias p is << signal .diag_tb.dut_o.push : std_logic >>;
    variable n : natural := 0;
  begin
    wait until rising_edge(clk);
    if p = '1' then
      n := n + 1;
      pushes_o <= n;
      ptime_o <= now - frame_start;
    end if;
  end process mon_o;

  stim : process
    type stat_t is array (0 to 1, 0 to 1) of natural;
    variable tot_e, bad_e, tot_o, bad_o : stat_t := (others => (others => 0));
    variable fails      : natural := 0;
    variable b0e, b0o   : natural;
    variable bits       : std_logic_vector(DATA_BITS-1 downto 0);
    variable pe, po     : std_logic;
    variable d7         : integer;

    function par(v : std_logic_vector; t : std_logic) return std_logic is
      variable p : std_logic := t;
    begin
      for i in v'range loop
        p := p xor v(i);
      end loop;
      return p;
    end function;

    procedure drive(signal line : out std_logic; v : std_logic_vector; p : std_logic; k : integer) is
    begin
      if k = 0 then
        line <= '0';
      elsif k <= DATA_BITS then
        line <= v(k-1);
      elsif k = DATA_BITS + 1 then
        line <= p;
      else
        line <= '1';
      end if;
    end procedure;

    procedure drain(signal pp : out std_logic; signal e : in std_logic; signal d : in std_logic_vector;
                    got : out integer; cnt : out natural) is
      variable n : natural := 0;
    begin
      got := -1;
      while e = '0' loop
        pp <= '1';
        wait until rising_edge(clk);
        wait for 1 ns;
        pp <= '0';
        if n = 0 then
          got := to_integer(unsigned(d));
        end if;
        n := n + 1;
      end loop;
      cnt := n;
    end procedure;

    variable got_e, got_o   : integer;
    variable cnt_e, cnt_o   : natural;
    variable ok             : boolean;

    procedure check_one(name : string; v : integer; good_parity : boolean; pbit : std_logic;
                        n_push : natural; pt : time; got : integer; in_fifo : natural; err : std_logic;
                        res : out boolean) is
      variable b : std_logic_vector(DATA_BITS-1 downto 0);
      variable r : boolean;
    begin
      b := std_logic_vector(to_unsigned(v, DATA_BITS));
      if good_parity then
        r := n_push = 1 and in_fifo = 1 and got = v and err = '0'
              and pt > (FRAME_LEN - 1) * BIT_TIME and pt < (FRAME_LEN + 1) * BIT_TIME;
      else
        r := n_push = 0 and in_fifo = 0 and err = '1';
      end if;
      if (not r) or SHOW_PASS then
        if r then
          report name & " value=" & integer'image(v) & " bits(D7..D0)=" & bin(b)
               & " parity_bit=" & std_logic'image(pbit) & " OK";
        else
          report name & " value=" & integer'image(v) & " bits(D7..D0)=" & bin(b)
               & " parity_bit=" & std_logic'image(pbit)
               & " | pushes=" & integer'image(n_push)
               & " last_push_at_bit=" & push_pos(n_push, pt)
               & " fifo_count=" & integer'image(in_fifo)
               & " first_byte=" & integer'image(got)
               & " uart_err=" & std_logic'image(err)
            severity error;
        end if;
      end if;
      res := r;
    end procedure;

  begin
    for i in 1 to 20 loop
      wait until rising_edge(clk);
    end loop;

    for pass in 0 to 1 loop
      if pass = 0 then
        report "===== pass 1: all values with CORRECT parity, every frame must be accepted =====";
      else
        report "===== pass 2: all values with WRONG parity, every frame must be dropped with uart_err=1 =====";
      end if;

      for v in 0 to 2**DATA_BITS - 1 loop
        bits := std_logic_vector(to_unsigned(v, DATA_BITS));
        pe := par(bits, '0');
        po := par(bits, '1');
        if pass = 1 then
          pe := not pe;
          po := not po;
        end if;
        d7 := 0;
        if bits(DATA_BITS-1) = '1' then
          d7 := 1;
        end if;

        b0e := pushes_e;
        b0o := pushes_o;
        frame_start <= now;
        for k in 0 to FRAME_LEN - 1 loop
          drive(rx_e, bits, pe, k);
          drive(rx_o, bits, po, k);
          wait for BIT_TIME;
        end loop;
        rx_e <= '1';
        rx_o <= '1';
        wait for BIT_TIME * 3;

        drain(pop_e, empty_e, data_e, got_e, cnt_e);
        drain(pop_o, empty_o, data_o, got_o, cnt_o);

        check_one("EVEN", v, pass = 0, pe, pushes_e - b0e, ptime_e, got_e, cnt_e, err_e, ok);
        if pass = 0 then
          tot_e(d7, to_integer(unsigned'("" & pe))) := tot_e(d7, to_integer(unsigned'("" & pe))) + 1;
          if not ok then
            bad_e(d7, to_integer(unsigned'("" & pe))) := bad_e(d7, to_integer(unsigned'("" & pe))) + 1;
          end if;
        end if;
        if not ok then
          fails := fails + 1;
        end if;

        check_one("ODD ", v, pass = 0, po, pushes_o - b0o, ptime_o, got_o, cnt_o, err_o, ok);
        if pass = 0 then
          tot_o(d7, to_integer(unsigned'("" & po))) := tot_o(d7, to_integer(unsigned'("" & po))) + 1;
          if not ok then
            bad_o(d7, to_integer(unsigned'("" & po))) := bad_o(d7, to_integer(unsigned'("" & po))) + 1;
          end if;
        end if;
        if not ok then
          fails := fails + 1;
        end if;
      end loop;
    end loop;

    report "===== summary of pass 1, failures by (D7, parity bit) =====";
    for a in 0 to 1 loop
      for b in 0 to 1 loop
        report "D7=" & integer'image(a) & " P=" & integer'image(b)
             & "  EVEN failed " & integer'image(bad_e(a, b)) & "/" & integer'image(tot_e(a, b))
             & "  ODD failed "  & integer'image(bad_o(a, b)) & "/" & integer'image(tot_o(a, b));
      end loop;
    end loop;

    if fails = 0 then
      report "DONE: no failures";
    else
      report "DONE: failures = " & integer'image(fails) severity error;
    end if;
    done <= true;
    wait;
  end process stim;

end architecture sim;